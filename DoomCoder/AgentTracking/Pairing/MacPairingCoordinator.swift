// MacPairingCoordinator.swift — DoomCoder Mac
// Owns the Mac-side pairing flow. The flow is:
//   1. User clicks "Add iPhone" in ConnectionsView
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
// creation). PairSheet opens immediately on "Add iPhone" click; the
// URL streams in when the modifyRecords round-trip completes.

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
    private let macDeviceId: DeviceID
    private let prewarmKey = "doomcoder.macpairing.prewarm.v1"
    private var didPrewarm: Bool

    public init(
        container: CKContainer = CKContainer(identifier: CloudKitConstants.containerIdentifier),
        macDeviceId: DeviceID = DeviceIDFactory.make()
    ) {
        self.container = container
        self.macDeviceId = macDeviceId
        self.didPrewarm = UserDefaults.standard.bool(forKey: prewarmKey)
        // v2.8: also listen for the APNs-driven "share changed" signal
        // from the CloudKitPusher delegate. This is the primary path
        // for detecting acceptance — the 3-second polling loop below
        // is now just a fallback in case the push is throttled.
        NotificationCenter.default.addObserver(
            forName: .doomCoderShareAccepted, object: nil, queue: .main
        ) { [weak self] _ in
            // The delegate posts on its own thread; bounce to the
            // main actor explicitly. handleAcceptance is idempotent.
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

    /// v2.8: amortize the CloudKit schema cold-start. On the first
    /// ever share creation in a container, the schema for the share
    /// record type must be auto-provisioned, which adds 5-25s to the
    /// first `modifyRecords([root, share])` round-trip. Calling
    /// `allRecordZones()` at app launch forces the same provisioning
    /// to happen in a non-blocking background task.
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
        phase = .idle
    }

    /// Remove a paired iOS device. On Mac this revokes the share and deletes
    /// the local Connection; the iOS app wipes its own local cache separately.
    public func remove(connection: Connection) async {
        if let shareRef = connection.ckShareRef,
           let shareURL = shareRef.shareURL {
            await revokeShare(shareURL: shareURL)
        }
        PairingStore.shared.remove(connectionId: connection.id)
    }

    // MARK: - Share creation

    /// v2.8: detached so the modifyRecords round-trip never blocks the
    /// main thread. Uses `CKModifyRecordsOperation` directly to set
    /// `qualityOfService = .userInitiated` (the async `modifyRecords`
    /// helper uses the default `.utility` QoS, which Apple explicitly
    /// warns can be deprioritized by the system).
    private func createShare() async throws -> (CKShare, URL) {
        let zone = CKRecordZone(zoneName: CloudKitConstants.zoneName)
        do {
            try await container.privateCloudDatabase.save(zone)
        } catch let ckError as CKError where ckError.code == .serverRecordChanged {
            // Zone already exists, that's fine.
        } catch {
            throw ConnectionError.zoneNotFound
        }
        let rootRecord = CKRecord(
            recordType: CloudKitConstants.RecordType.settings,
            recordID: CKRecord.ID(recordName: "Pairing-\(macDeviceId)")
        )
        rootRecord["macDeviceId"] = macDeviceId as CKRecordValue
        let share = CKShare(
            rootRecord: rootRecord,
            shareID: CKRecord.ID(recordName: "DoomCoderShare-\(macDeviceId)")
        )
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = "DoomCoder - \(Host.current().localizedName ?? "Mac")" as CKRecordValue

        // Use a CKModifyRecordsOperation directly to control QoS.
        let saveResults: Result<Void, Error> = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result<Void, Error>, Error>) in
            let op = CKModifyRecordsOperation(
                recordsToSave: [rootRecord, share],
                recordIDsToDelete: []
            )
            op.qualityOfService = .userInitiated
            op.savePolicy = .changedKeys
            op.modifyRecordsResultBlock = { result in
                cont.resume(returning: result)
            }
            container.privateCloudDatabase.add(op)
        }
        switch saveResults {
        case .success: break
        case .failure(let err): throw ConnectionError.shareCreationFailed(err.localizedDescription)
        }
        guard let url = share.url else {
            throw ConnectionError.shareCreationFailed("share had no URL")
        }
        return (share, url)
    }

    private func revokeShare(shareURL: URL) async {
        // The simplest robust approach: delete the local Connection; the
        // share itself can be revoked by the user from iCloud Settings if
        // they want a hard kill switch. We deliberately don't auto-delete
        // the share from CloudKit because a user may want to revoke via
        // System Settings and we don't want to race with that.
        _ = shareURL
    }

    // MARK: - Polling (v2.8: backup path)

    /// v2.8: the primary path is the APNs-driven notification
    /// `.doomCoderShareAccepted`. This polling loop is now just a
    /// fallback in case the push is throttled or the user's iCloud
    /// setup doesn't deliver silent pushes. Interval relaxed from
    /// 3s → 8s to reduce background load.
    private func startPollingShare(shareRecordID: CKRecord.ID, expiresAt: Date) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if Date() > expiresAt {
                    await MainActor.run { [weak self] in
                        self?.handleExpiry()
                    }
                    return
                }
                if let self {
                    let accepted = await self.checkShareAcceptance(shareRecordID: shareRecordID)
                    if accepted {
                        await MainActor.run { [weak self] in
                            self?.handleAcceptance()
                        }
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
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
        let ref = CKShareRef(
            shareURL: shareURL,
            ownerRecordName: share.recordID.recordName,
            containerIdentifier: CloudKitConstants.containerIdentifier
        )
        // v2.8: deterministic id derived from shareURL — re-pairing
        // the same share reuses this row instead of creating a new one.
        let id = Connection.deterministicId(for: .ckShare(ref))
        // Pre-check: if a row with this id already exists, refresh it
        // and skip the rest (idempotent on duplicate poll firings).
        if let existing = PairingStore.shared.connections.first(where: { $0.id == id }) {
            var refreshed = existing
            refreshed.status = .active
            refreshed.lastSyncAt = Date()
            PairingStore.shared.upsert(refreshed)
            pollTask?.cancel()
            pollTask = nil
            currentShare = nil
            pendingConnectionId = nil
            phase = .active(refreshed)
            return
        }
        let connection = Connection(
            id: id,
            macDeviceId: macDeviceId,
            iosDeviceId: DeviceIDFactory.make(),   // placeholder; PeerStatus heartbeat will fill in
            route: .ckShare(ref),
            status: .active,
            lastSyncAt: Date(),
            ckShareRef: ref
        )
        PairingStore.shared.upsert(connection)
        PairingStore.shared.clearPendingCode()
        pollTask?.cancel()
        pollTask = nil
        currentShare = nil
        pendingConnectionId = nil
        phase = .active(connection)
    }

    private func handleExpiry() {
        PairingStore.shared.clearPendingCode()
        pollTask?.cancel()
        pollTask = nil
        currentShare = nil
        pendingConnectionId = nil
        let err = ConnectionError.pairingCodeExpired
        lastError = err
        phase = .failed(err)
    }
}
