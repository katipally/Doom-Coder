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

    /// Same-iCloud code/QR payload, shown alongside the AirDrop-style picker so
    /// the user can also pair by typing a code or scanning a QR on the iPhone.
    /// Independent of `phase` (which is the cross-account CKShare state machine).
    public struct SameICloudCode: Equatable, Sendable {
        public let code: String      // 6-char code (also resolvable via public DB)
        public let payloadURL: URL   // doomcoder://pair?sameICloud=1&… (QR + link)
        public let expiresAt: Date
    }
    @Published public private(set) var sameICloudCode: SameICloudCode?
    private var sameICloudCodeKey: String?   // public-DB record name for the code
    private var sameICloudExpiryTask: Task<Void, Never>?

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

    /// v6: Mac-initiated same-iCloud pairing. The user picked an iPhone in the
    /// Add-Device "Same iCloud" AirDrop-style list. We create an awaiting row
    /// and send a CSC{requested, origin:mac}; because we're on the same Apple
    /// ID, the iPhone's private-DB engine fetches it and surfaces an
    /// Accept/Decline prompt. On accept it sends CSC{accepted, origin:ios},
    /// which our ingest turns into an active connection.
    public func requestSameICloudPair(device: DiscoverableDeviceRecord) async {
        // v7: promptless direct-connect. Same iCloud = same trusted account, so
        // tapping the device records the pairing immediately — no Accept prompt,
        // no CSC handshake. "Connected" is then DERIVED once the iPhone's
        // DeviceRecord is observed in the zone (the iPhone, on the same account,
        // already writes its DeviceRecord into the shared private zone). We seed
        // a placeholder so the card shows the name instantly; the real
        // DeviceRecord refreshes it.
        let id = Connection.implicitConnectionId(macId: macDeviceId, iosDeviceId: device.iosDeviceId)
        // If the iPhone's DeviceRecord is already in the store, the connection
        // is born active; otherwise pending until it arrives.
        let peer = IosDeviceProfileCache.shared.record(for: device.iosDeviceId)
        let derived = DerivedDeviceState.derive(hasPairing: true, peer: peer)
        let conn = Connection(
            id: id,
            macDeviceId: macDeviceId,
            iosDeviceId: device.iosDeviceId,
            route: .iCloud,
            status: derived == .active ? .active : .pending,
            createdAt: Date(),
            lastSyncAt: peer?.lastSeen,
            ckShareRef: nil,
            pairingOrigin: .sameICloud,
            stateChangeCounter: 1,
            shareAcceptedAt: Date()
        )
        PairingStore.shared.upsert(conn)
        IosDeviceProfileCache.shared.insertPlaceholder(iosDeviceId: device.iosDeviceId, name: device.name)
        if derived == .active {
            NotificationDispatcher.shared.notifyDeviceConnected(name: device.name)
        }
    }

    // MARK: - Same-iCloud code / QR (alternative to the picker)

    /// Generate and publish a same-iCloud pairing code + QR payload. The iPhone
    /// can type the code, scan the QR, or open the link to connect without the
    /// picker. No CKShare — the payload carries this Mac's id + iCloud user
    /// record name so the iPhone can verify same-account and run the CSC
    /// handshake. Idempotent while a live code already exists.
    public func startSameICloudCodeIfNeeded() async {
        if let existing = sameICloudCode, existing.expiresAt > Date() { return }
        // Need the REAL CloudKit user record name (not CKCurrentUserDefaultName)
        // so the iPhone can compare it against its own account identity.
        if macUserRecordName == CKCurrentUserDefaultName,
           let userID = try? await container.userRecordID() {
            macUserRecordName = userID.recordName
        }
        guard macUserRecordName != CKCurrentUserDefaultName else { return }
        let code = PairingStore.shared.generatePendingCode()
        guard let payload = Self.sameICloudDeepLink(
            macId: macDeviceId,
            macUserRecordID: macUserRecordName
        ) else { return }
        sameICloudCode = SameICloudCode(code: code.code, payloadURL: payload, expiresAt: code.expiresAt)
        await publishSameICloudCode(code.code, expiresAt: code.expiresAt)
        // Auto-clear when the code expires so the UI doesn't show a dead code.
        sameICloudExpiryTask?.cancel()
        let interval = code.expiresAt.timeIntervalSinceNow
        sameICloudExpiryTask = Task { [weak self] in
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            if !Task.isCancelled { self?.stopSameICloudCode() }
        }
    }

    /// Delete the published same-iCloud code and clear local state.
    public func stopSameICloudCode() {
        sameICloudExpiryTask?.cancel()
        sameICloudExpiryTask = nil
        sameICloudCode = nil
        guard let key = sameICloudCodeKey else { return }
        sameICloudCodeKey = nil
        let db = container.publicCloudDatabase
        Task.detached(priority: .utility) {
            _ = try? await db.deleteRecord(withID: CKRecord.ID(recordName: key))
        }
    }

    private func publishSameICloudCode(_ code: String, expiresAt: Date) async {
        let key = code.uppercased()
        let recordID = CKRecord.ID(recordName: key)
        let record = CKRecord(
            recordType: CloudKitConstants.RecordType.pairingCode,
            recordID: recordID
        )
        record["kind"] = "sameICloud" as CKRecordValue
        record["macId"] = macDeviceId as CKRecordValue
        record["macUserRecordID"] = macUserRecordName as CKRecordValue
        record["expiresAt"] = expiresAt as CKRecordValue
        do {
            try await container.publicCloudDatabase.save(record)
            sameICloudCodeKey = key
        } catch {
            // Non-fatal: the QR / link still work (they're self-contained); only
            // typing the 6-char code needs the public-DB lookup.
        }
    }

    static func sameICloudDeepLink(macId: String, macUserRecordID: String) -> URL? {
        var c = URLComponents()
        c.scheme = "doomcoder"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "sameICloud", value: "1"),
            URLQueryItem(name: "macId", value: macId),
            URLQueryItem(name: "macUser", value: macUserRecordID),
            URLQueryItem(name: "container", value: CloudKitConstants.containerIdentifier)
        ]
        return c.url
    }

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
        stopSameICloudCode()
        phase = .idle
    }

    /// Remove a paired iOS device. Revokes the share from CloudKit and
    /// deletes the local Connection. The iOS app wipes its own local
    /// cache separately on next launch.
    public func remove(connection: Connection) async {
        // v7: disconnect = delete the peer's DeviceRecord from the zone and
        // (for different-iCloud) revoke the CKShare so the iPhone loses zone
        // access. The iPhone, fetching the deletion / losing the zone, derives
        // `.disconnected` and tears down its own side — no CSC handshake.
        if !connection.iosDeviceId.isEmpty,
           let engine = CloudKitPusher.shared.engine {
            let zoneID = CKRecordZone.ID(
                zoneName: CloudKitConstants.zoneName,
                ownerName: CKCurrentUserDefaultName
            )
            let peerRecordID = CKRecord.ID(
                recordName: "Device-\(connection.iosDeviceId)",
                zoneID: zoneID
            )
            engine.state.add(pendingRecordZoneChanges: [.deleteRecord(peerRecordID)])
            CloudKitPusher.shared.kickEngine()
        }
        if let shareRef = connection.ckShareRef,
           let shareURL = shareRef.shareURL {
            await revokeShare(shareURL: shareURL)
        }
        // v7: no suppression — a disconnected iPhone simply leaves the list and
        // stays discoverable in the picker for an explicit re-pair.
        IosDeviceProfileCache.shared.remove(deviceId: connection.iosDeviceId)
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

    // MARK: - Acceptance (v6: event-driven, expiry-only timer)

    private func startPollingShare(shareRecordID: CKRecord.ID, expiresAt: Date) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // v6: acceptance arrives via the `.doomCoderShareAccepted` APNs push
            // (CloudKitPusher delegate). One belt-and-braces check covers the
            // race where the push landed before the sheet opened; after that we
            // only wait out the expiry deadline — NO 3s polling loop.
            if let self, await self.checkShareAcceptance(shareRecordID: shareRecordID) {
                await MainActor.run { [weak self] in self?.handleAcceptance() }
                return
            }
            let interval = expiresAt.timeIntervalSinceNow
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            if !Task.isCancelled {
                await MainActor.run { [weak self] in self?.handleExpiry() }
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

    /// Extracts the iPhone user's iCloud identity (name/email) from the
    /// accepted share's non-owner participant. Non-deprecated; populated only
    /// if the participant shared their identity. Different-Apple-ID only —
    /// same-account shares have no non-owner participant.
    private static func peerIdentity(from share: CKShare) -> (name: String?, email: String?) {
        guard let participant = share.participants.first(where: { $0.role != .owner }),
              let identity = participant.userIdentity as CKUserIdentity?
        else { return (nil, nil) }
        let name: String? = identity.nameComponents.map {
            PersonNameComponentsFormatter().string(from: $0)
        }.flatMap { $0.isEmpty ? nil : $0 }
        let email = identity.lookupInfo?.emailAddress
        return (name, (email?.isEmpty == false) ? email : nil)
    }

    private func handleAcceptance() {
        guard let share = currentShare,
              let shareURL = share.url,
              let _ = pendingConnectionId else { return }
        deletePublishedCode()
        let peer = Self.peerIdentity(from: share)
        let ref = CKShareRef(
            shareURL: shareURL,
            ownerRecordName: macUserRecordName,
            containerIdentifier: CloudKitConstants.containerIdentifier
        )
        let id = Connection.deterministicId(for: .ckShare(ref))
        if let existing = PairingStore.shared.connections.first(where: { $0.id == id }) {
            var refreshed = existing
            refreshed.shareAcceptedAt = refreshed.shareAcceptedAt ?? Date()
            if let n = peer.name { refreshed.peerAccountName = n }
            if let e = peer.email { refreshed.peerAccountEmail = e }
            // v7: "connected" is DERIVED once the iPhone's DeviceRecord lands;
            // reflect the current derivation now so the UI is consistent.
            refreshed.status = IosDeviceProfileCache.shared.derivedState(for: refreshed) == .active ? .active : .pending
            PairingStore.shared.upsert(refreshed)
            pollTask?.cancel()
            pollTask = nil
            currentShare = nil
            pendingConnectionId = nil
            phase = .active(refreshed)
            return
        }
        // v7: iosDeviceId starts empty; the iPhone's first DeviceRecord
        // (fetched out of the shared zone) back-fills it and flips the derived
        // state to .active. We never pre-allocate a random placeholder id.
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
            shareAcceptedAt: Date(),
            peerAccountName: peer.name,
            peerAccountEmail: peer.email
        )
        // A .pending row so the Mac Connections tab shows "Connecting…"
        // immediately; the derivation flips it to "Connected" the moment the
        // iPhone's DeviceRecord appears in the shared zone.
        PairingStore.shared.upsert(connection)
        PairingStore.shared.clearPendingCode()
        pollTask?.cancel()
        pollTask = nil
        currentShare = nil
        pendingConnectionId = nil
        phase = .active(connection)
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
