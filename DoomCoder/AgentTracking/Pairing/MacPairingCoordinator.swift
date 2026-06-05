// MacPairingCoordinator.swift — DoomCoder Mac
// Owns the Mac-side pairing flow. The flow is:
//   1. User clicks "Add Device" in ConnectionsView
//   2. Coordinator creates a CKShare on the DoomCoderZone with the Mac as
//      owner, opts the iPhone user in, and uploads the share
//   3. Coordinator hands the share URL + a short code to the UI (PairSheet)
//   4. iPhone scans the QR / types the code, accepts the share, the
//      CKContainer.accept(...) callback returns success
//   5. Coordinator watches the share participant list and, when the
//      iPhone user appears, marks the Connection .active
//   6. CloudKitPusher picks up the new connection and fans out updates
//
// v2.8 latency: prewarm the container at app launch to amortize the
// CloudKit schema cold-start penalty (5-25s on first-ever share
// creation). PairSheet opens immediately on "Add Device" click; the
// URL streams in when the modifyRecords round-trip completes.
//
// v2.9 fixes:
//   • perRecordSaveBlock added — captures server-returned CKShare with
//     populated .url (was nil before, causing the QR to spin forever)
//   • macDeviceId reads the same stable key as CloudKitPusher so dedup
//     in ingestPeerStatus actually matches (was random per-launch before)
//   • share.publicPermission = .readWrite so cross-account iOS devices
//     can write PeerStatus back into the shared zone for instant discovery
//   • macUserRecordName stored at share-creation time so CKShareRef carries
//     the real CloudKit user record name (needed for shared-zone writes)
//   • revokeShare() is now a real CloudKit delete (was a no-op)

import Foundation
import CloudKit
import Combine
import DoomCoderCore

@MainActor
public final class MacPairingCoordinator: ObservableObject {

    public static let shared = MacPairingCoordinator()

    public enum Phase: Equatable, Sendable {
        case idle
        case creatingShare
        case waitingForAcceptance(code: String, shareURL: URL, expiresAt: Date)
        case active(Connection)
        case failed(ConnectionError)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var lastError: ConnectionError?

    private let container: CKContainer
    private var pollTask: Task<Void, Never>?
    private var currentShare: CKShare?
    private var pendingConnectionId: String?
    private var macUserRecordName: String = CKCurrentUserDefaultName
    private let macDeviceId: DeviceID
    private let prewarmKey = "doomcoder.macpairing.prewarm.v1"
    private var didPrewarm: Bool
    private var publishedCodeKey: String?   // current public-DB record name

    /// Reads from the same UserDefaults key as CloudKitPusher.stableMacID()
    /// so both coordinators agree on this Mac's identity.
    private static func resolveMacDeviceId() -> DeviceID {
        let key = "doomcoder.ckpusher.macId.v1"
        if let cached = UserDefaults.standard.string(forKey: key), !cached.isEmpty {
            return cached
        }
        // CloudKitPusher hasn't written the key yet (very first launch);
        // fall through to its stable value via the shared singleton.
        return CloudKitPusher.shared.macId
    }

    public init(
        container: CKContainer = CKContainer(identifier: CloudKitConstants.containerIdentifier)
    ) {
        self.container = container
        self.macDeviceId = Self.resolveMacDeviceId()
        self.didPrewarm = UserDefaults.standard.bool(forKey: "doomcoder.macpairing.prewarm.v1")
        // v2.8: also listen for the APNs-driven "share changed" signal
        // from the CloudKitPusher delegate. This is the primary path
        // for detecting acceptance — the polling loop below is just a
        // fallback in case the push is throttled.
        NotificationCenter.default.addObserver(
            forName: .doomCoderShareAccepted, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAcceptance()
            }
        }
    }

    deinit {
        pollTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Prewarm

    public func prewarmContainer() {
        guard !didPrewarm else { return }
        let database = container.privateCloudDatabase
        Task.detached(priority: .background) { [weak self] in
            _ = try? await database.allRecordZones()
            await MainActor.run {
                UserDefaults.standard.set(true, forKey: self?.prewarmKey ?? "doomcoder.macpairing.prewarm.v1")
                self?.didPrewarm = true
            }
        }
    }

    // MARK: - Public API

    public func startPairing() async {
        phase = .creatingShare
        do {
            // Fetch the Mac's CloudKit user record name upfront so it can
            // be stored in the CKShareRef — iOS uses it to address the
            // shared zone when writing PeerStatus heartbeats back.
            if let userID = try? await container.userRecordID() {
                macUserRecordName = userID.recordName
            }
            let (share, url) = try await createShare()
            currentShare = share
            let code = PairingStore.shared.generatePendingCode()
            pendingConnectionId = UUID().uuidString
            phase = .waitingForAcceptance(
                code: code.code,
                shareURL: url,
                expiresAt: code.expiresAt
            )
            startPollingShare(shareRecordID: share.recordID, expiresAt: code.expiresAt)
            // Publish code → shareURL to public DB so iOS can pair by typing the code.
            await publishCode(code.code, shareURL: url)
        } catch let err as ConnectionError {
            lastError = err
            phase = .failed(err)
        } catch {
            let wrapped = ConnectionError.shareCreationFailed(error.localizedDescription)
            lastError = wrapped
            phase = .failed(wrapped)
        }
    }

    public func cancelPairing() {
        pollTask?.cancel()
        pollTask = nil
        pendingConnectionId = nil
        currentShare = nil
        PairingStore.shared.clearPendingCode()
        deletePublishedCode()
        phase = .idle
    }

    /// Remove a paired iOS device. Revokes the share from CloudKit and
    /// deletes the local Connection. The iOS app wipes its own local
    /// cache separately on next launch.
    public func remove(connection: Connection) async {
        if let shareRef = connection.ckShareRef,
           let shareURL = shareRef.shareURL {
            await revokeShare(shareURL: shareURL)
        }
        // v5: signal the iOS app before local teardown so it
        // receives a CSC within 1-3s instead of waiting for
        // the next PeerStatus heart-beat.
        var snapshot = connection
        snapshot.stateChangeCounter += 1
        snapshot.status = .removed
        snapshot.removedAt = Date()
        await ConnectionStateChanges.shared.publish(
            state: .removed,
            for: snapshot,
            origin: .mac
        )
        PairingStore.shared.remove(connectionId: connection.id)
    }

    // MARK: - Share creation

    private func createShare() async throws -> (CKShare, URL) {
        // All records must live in DoomCoderZone, not the default zone.
        let zoneID = CKRecordZone.ID(
            zoneName: CloudKitConstants.zoneName,
            ownerName: CKCurrentUserDefaultName
        )
        let zone = CKRecordZone(zoneID: zoneID)
        do {
            try await container.privateCloudDatabase.save(zone)
        } catch let ckErr as CKError where ckErr.code == .serverRecordChanged {
            // Zone already exists — fine.
        } catch {
            throw ConnectionError.zoneNotFound
        }

        // If a share already exists (e.g., from a previous "Add Device" tap that was
        // never accepted), reuse it instead of creating a new one. This avoids
        // serverRecordChanged failures on every subsequent startPairing() call.
        let shareRecordID = CKRecord.ID(
            recordName: "DoomCoderShare-\(macDeviceId)",
            zoneID: zoneID
        )
        if let existingShare = try? await container.privateCloudDatabase.record(for: shareRecordID) as? CKShare,
           let url = existingShare.url {
            if existingShare.publicPermission != .readWrite {
                existingShare.publicPermission = .readWrite
                _ = try? await container.privateCloudDatabase.save(existingShare)
            }
            currentShare = existingShare
            return (existingShare, url)
        }

        // No existing share — create a fresh one.
        let rootRecord = CKRecord(
            recordType: CloudKitConstants.RecordType.settings,
            recordID: CKRecord.ID(recordName: "Pairing-\(macDeviceId)", zoneID: zoneID)
        )
        rootRecord["macDeviceId"] = macDeviceId as CKRecordValue

        let share = CKShare(rootRecord: rootRecord, shareID: shareRecordID)
        share.publicPermission = .readWrite
        share[CKShare.SystemFieldKey.title] = "DoomCoder - \(Host.current().localizedName ?? "Mac")" as CKRecordValue

        // perRecordSaveBlock is essential: it receives the server-returned
        // CKShare, which is the only copy that has .url populated.
        // Also handles serverRecordChanged (race between two taps) by
        // extracting the server version from CKError.serverRecord.
        var savedShare: CKShare?
        let opResult: Result<Void, Error> = try await withCheckedThrowingContinuation { cont in
            let op = CKModifyRecordsOperation(
                recordsToSave: [rootRecord, share],
                recordIDsToDelete: []
            )
            op.qualityOfService = .userInitiated
            op.savePolicy = .changedKeys
            op.perRecordSaveBlock = { _, result in
                switch result {
                case .success(let saved):
                    if let s = saved as? CKShare { savedShare = s }
                case .failure(let err):
                    // Race condition: another operation saved the share first.
                    // CKError.serverRecord carries the current server version.
                    if let ckErr = err as? CKError,
                       ckErr.code == .serverRecordChanged,
                       let serverShare = ckErr.serverRecord as? CKShare {
                        savedShare = serverShare
                    }
                }
            }
            op.modifyRecordsResultBlock = { result in cont.resume(returning: result) }
            container.privateCloudDatabase.add(op)
        }
        switch opResult {
        case .success: break
        case .failure(let err):
            // If we recovered the CKShare from a serverRecordChanged error,
            // the share is valid — don't throw.
            if savedShare == nil {
                throw ConnectionError.shareCreationFailed(err.localizedDescription)
            }
        }

        let finalShare = savedShare ?? share
        guard let url = finalShare.url else {
            throw ConnectionError.shareCreationFailed("Share had no URL after creation — check CloudKit container entitlements.")
        }
        currentShare = finalShare
        return (finalShare, url)
    }

    /// v2.9: hard-revoke — deletes both the share record and its root
    /// record from CloudKit so the iOS participant truly loses zone access.
    /// The previous implementation was a no-op.
    private func revokeShare(shareURL: URL) async {
        // Reconstruct the share and root record IDs from their deterministic names.
        let zoneID = CKRecordZone.ID(
            zoneName: CloudKitConstants.zoneName,
            ownerName: CKCurrentUserDefaultName
        )
        let shareRecordID = CKRecord.ID(
            recordName: "DoomCoderShare-\(macDeviceId)",
            zoneID: zoneID
        )
        let rootRecordID = CKRecord.ID(
            recordName: "Pairing-\(macDeviceId)",
            zoneID: zoneID
        )
        let op = CKModifyRecordsOperation(
            recordsToSave: nil,
            recordIDsToDelete: [shareRecordID, rootRecordID]
        )
        op.qualityOfService = .userInitiated
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            op.modifyRecordsResultBlock = { _ in cont.resume() }
            container.privateCloudDatabase.add(op)
        }
    }

    // MARK: - Polling (v2.8: backup path)

    private func startPollingShare(shareRecordID: CKRecord.ID, expiresAt: Date) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if Date() > expiresAt {
                    await MainActor.run { [weak self] in self?.handleExpiry() }
                    return
                }
                if let self {
                    // Check for non-owner participants (cross-account path).
                    // Same-account pairings are detected via PeerStatus heartbeat
                    // in ingestPeerStatus(), so no participant will ever appear here
                    // for same-account — that's expected, not a bug.
                    let accepted = await self.checkShareAcceptance(shareRecordID: shareRecordID)
                    if accepted {
                        await MainActor.run { [weak self] in self?.handleAcceptance() }
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func checkShareAcceptance(shareRecordID: CKRecord.ID) async -> Bool {
        do {
            let record = try await container.privateCloudDatabase.record(for: shareRecordID)
            guard let share = record as? CKShare else { return false }
            return !(share.participants.filter { $0.role != .owner }).isEmpty
        } catch {
            return false
        }
    }

    private func handleAcceptance() {
        guard let share = currentShare,
              let shareURL = share.url,
              let _ = pendingConnectionId else { return }
        deletePublishedCode()
        let ref = CKShareRef(
            shareURL: shareURL,
            ownerRecordName: macUserRecordName,
            containerIdentifier: CloudKitConstants.containerIdentifier
        )
        let id = Connection.deterministicId(for: .ckShare(ref))
        if let existing = PairingStore.shared.connections.first(where: { $0.id == id }) {
            var refreshed = existing
            refreshed.status = .active
            refreshed.lastSyncAt = Date()
            refreshed.shareAcceptedAt = Date()
            refreshed.stateChangeCounter += 1
            PairingStore.shared.upsert(refreshed)
            // v5: echo an accepted CSC to the iOS side so the
            // iPhone gets an instant ack and can dismiss the
            // success sheet without waiting for the next
            // PeerStatus heart-beat.
            Task { @MainActor in
                await ConnectionStateChanges.shared.publish(
                    state: .accepted,
                    for: refreshed,
                    origin: .mac
                )
            }
            pollTask?.cancel()
            pollTask = nil
            currentShare = nil
            pendingConnectionId = nil
            phase = .active(refreshed)
            return
        }
        // v5: iosDeviceId starts empty; the iOS app's first
        // PeerStatus heart-beat (or the v5
        // ConnectionStateChange{reinstall-detected} fast path)
        // back-fills it. We never pre-allocate a placeholder
        // random id — that was the source of the v2.9
        // "duplicates on the Mac" bug.
        let connection = Connection(
            id: id,
            macDeviceId: macDeviceId,
            iosDeviceId: "",
            route: .ckShare(ref),
            status: .pending,
            createdAt: Date(),
            lastSyncAt: nil,
            ckShareRef: ref,
            pairingOrigin: .qr,
            stateChangeCounter: 1,
            shareAcceptedAt: nil
        )
        // First a .pending row so the Mac Connections tab
        // shows "Waiting for iPhone" immediately, then an
        // .active row + CSC echo as soon as we know the iOS
        // app accepted. Single round-trip to the user.
        PairingStore.shared.upsert(connection)
        PairingStore.shared.clearPendingCode()
        var active = connection
        active.status = .active
        active.lastSyncAt = Date()
        active.shareAcceptedAt = Date()
        active.stateChangeCounter += 1
        PairingStore.shared.upsert(active)
        Task { @MainActor in
            await ConnectionStateChanges.shared.publish(
                state: .accepted,
                for: active,
                origin: .mac
            )
        }
        pollTask?.cancel()
        pollTask = nil
        currentShare = nil
        pendingConnectionId = nil
        phase = .active(active)
    }

    private func handleExpiry() {
        deletePublishedCode()
        PairingStore.shared.clearPendingCode()
        pollTask?.cancel()
        pollTask = nil
        currentShare = nil
        pendingConnectionId = nil
        let err = ConnectionError.pairingCodeExpired
        lastError = err
        phase = .failed(err)
    }

    // MARK: - Public-DB pairing code

    /// Writes a DCPairingCode record to the public database so iOS can look up
    /// the share URL by typing the 6-char code instead of scanning the QR.
    private func publishCode(_ code: String, shareURL: URL) async {
        let key = code.uppercased()
        let recordID = CKRecord.ID(recordName: key)
        let record = CKRecord(
            recordType: CloudKitConstants.RecordType.pairingCode,
            recordID: recordID
        )
        record["shareURL"] = shareURL.absoluteString as CKRecordValue
        record["expiresAt"] = Date().addingTimeInterval(PairingCode.lifetime) as CKRecordValue
        do {
            try await container.publicCloudDatabase.save(record)
            publishedCodeKey = key
        } catch {
            // Non-fatal: QR scan still works. Code typing just won't be available.
        }
    }

    /// Fire-and-forget deletion of the public-DB pairing code record.
    private func deletePublishedCode() {
        guard let key = publishedCodeKey else { return }
        publishedCodeKey = nil
        let db = container.publicCloudDatabase
        Task.detached(priority: .utility) {
            _ = try? await db.deleteRecord(withID: CKRecord.ID(recordName: key))
        }
    }
}
