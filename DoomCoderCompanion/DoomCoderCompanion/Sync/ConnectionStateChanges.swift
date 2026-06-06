// ConnectionStateChanges.swift — DoomCoder Companion
// v5: writer + observer for the cross-device state-change record
// (see `ConnectionStateChangeRecord` in DoomCoderCore). The
// architecture is symmetrical on Mac and iOS:
//
//   ┌──────────────┐  write CSC{state, origin: ios}  ┌──────────────┐
//   │  iOS side    │ ──────────────────────────────► │  Mac side    │
//   │              │ ◄────────────────────────────── │              │
//   │              │   CSC{state, origin: mac} echo  │              │
//   └──────────────┘                                └──────────────┘
//
// Both sides have a CKSyncEngine subscribed to DoomCoderZone (or,
// for cross-account CKShare, the shared zone owned by the Mac).
// When a CSC record is written, CloudKit sends an APNs silent push
// to the other device within 1-3s. The engine picks the record up,
// `ingest(_:)` runs on the receiving side, and `ConnectionStore`
// is updated + the UI re-renders.
//
// The `stateChangeCounter` field on every Connection is the
// monotonic ordering key. CSC records carry the counter value
// at the time of the transition; the receiving side rejects
// records whose counter is <= the local last-seen value. This
// makes the system safe against:
//   • out-of-order APNs replays
//   • the rare case where a CSC and a PeerStatus heart-beat race
//
// Two write paths are involved (v6):
//   1. Private DB engine (CompanionSyncEngine on iOS, CloudKitPusher on
//      Mac) — for same-Apple-ID writes.
//   2. Direct `CKModifyRecordsOperation` against the Mac's shared DB —
//      for cross-account (CKShare) writes from iOS into the Mac's shared
//      zone. (The single shared-DB engine, SharedDatabaseSync, only
//      READS; it doesn't manage these writes.)
//
// Routing is per-Connection: same-account connections go through the
// private engine; cross-account connections write to the shared DB.

import Foundation
import CloudKit
import OSLog
import DoomCoderCore

@MainActor
final class ConnectionStateChanges {
    static let shared = ConnectionStateChanges()

    private let container: CKContainer
    private let logger = Logger(subsystem: "com.doomcoder", category: "csc")
    /// Per-shared-zone server record cache for the direct-write fast
    /// path. Key is the (macId, iosDeviceId) tuple. Mirrors the
    /// pattern used elsewhere in the codebase for recordChangeTag
    /// preservation.
    private var sharedDbServerCache: [String: CKRecord] = [:]
    /// Per-private-zone server record cache (used by the iOS private
    /// engine's batch delegate, like PeerStatusPublisherCache).
    private var privateDbServerCache: [String: CKRecord] = [:]

    private init(container: CKContainer = CKContainer(identifier: CloudKitConstants.containerIdentifier)) {
        self.container = container
    }

    // MARK: - Write path (the "I just transitioned" side)

    /// Publishes a state-change record to the other side. The
    /// counter used in the record name is the Connection's
    /// `stateChangeCounter + 1` — the receiving side expects to
    /// see a value strictly greater than the one it last applied.
    public func publish(
        state: ConnectionStateChangeRecord.State,
        for connection: Connection,
        origin: ConnectionStateChangeRecord.Origin,
        oldIosDeviceId: String? = nil,
        emailHint: String? = nil
    ) async {
        let counter = connection.stateChangeCounter
        let macId = connection.macDeviceId
        let iosId = connection.iosDeviceId
        let routeTag = connection.route.tag.rawValue
        let shareURL = connection.ckShareRef?.shareURLString
        let rec = ConnectionStateChangeRecord(
            macId: macId,
            iosDeviceId: iosId,
            state: state.rawValue,
            timestamp: Date(),
            origin: origin.rawValue,
            routeTag: routeTag,
            shareURLString: shareURL,
            routeAccountEmail: emailHint,
            oldIosDeviceId: oldIosDeviceId
        )

        // Route the write to the right engine.
        if case .ckShare(let ref) = connection.route, !ref.isSameAccount {
            await writeViaSharedDB(record: rec, counter: counter, ref: ref)
        } else {
            await writeViaPrivateEngine(record: rec, counter: counter)
        }
    }

    private func writeViaPrivateEngine(record: ConnectionStateChangeRecord, counter: Int) async {
        let engine = CompanionSyncEngine.shared.internalSyncEngine
        guard let engine else {
            // Engine isn't ready — fall back to a direct write so the
            // CSC still lands within 1-3s instead of being dropped.
            await writeDirectToPrivateDB(record: record, counter: counter)
            return
        }
        let ck = record.toCKRecord(counter: counter)
        // Materialise the recordChangeTag from the cache so savePolicy
        // .changedKeys is happy on the server.
        if let cached = privateDbServerCache[ck.recordID.recordName] {
            for key in ck.allKeys() { cached[key] = ck[key] }
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(ck.recordID)])
        } else {
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(ck.recordID)])
        }
        // Mirror in our local cache so the engine delegate can
        // materialise the record when the engine asks for it.
        CSCPendingCache.shared.put(ck, route: .privateDB)
    }

    private func writeDirectToPrivateDB(record: ConnectionStateChangeRecord, counter: Int) async {
        let ck = record.toCKRecord(counter: counter)
        let op = CKModifyRecordsOperation(recordsToSave: [ck], recordIDsToDelete: nil)
        op.savePolicy = .allKeys
        op.qualityOfService = .userInitiated
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            op.modifyRecordsResultBlock = { _ in cont.resume() }
            container.privateCloudDatabase.add(op)
        }
    }

    private func writeViaSharedDB(record: ConnectionStateChangeRecord, counter: Int, ref: CKShareRef) async {
        let zoneOwner = ref.ownerRecordName
        guard !zoneOwner.isEmpty else {
            logger.warning("csc: shared-DB write skipped — empty zoneOwner")
            return
        }
        let ck = record.toCKRecord(zoneOwner: zoneOwner, counter: counter)
        // Preserve recordChangeTag from cache when possible.
        if let cached = sharedDbServerCache[ck.recordID.recordName] {
            for key in ck.allKeys() { cached[key] = ck[key] }
        }
        let op = CKModifyRecordsOperation(recordsToSave: [ck], recordIDsToDelete: nil)
        op.savePolicy = .changedKeys
        op.qualityOfService = .userInitiated
        op.perRecordSaveBlock = { [weak self] _, result in
            if case .success(let saved) = result {
                Task { @MainActor [weak self] in
                    self?.sharedDbServerCache[saved.recordID.recordName] = saved
                }
            }
        }
        op.modifyRecordsResultBlock = { [weak self] result in
            if case .failure(let err) = result {
                Task { @MainActor [weak self] in
                    self?.logger.warning("csc: shared-DB write failed: \(err.localizedDescription, privacy: .public)")
                }
            }
        }
        container.sharedCloudDatabase.add(op)
    }

    // MARK: - Read path (the "the other side transitioned" side)

    /// Called from the CKSyncEngine delegate (both the private
    /// engine and the per-share engine) when a CSC record is
    /// fetched. Applies the transition to the local ConnectionStore
    /// and re-stamps the liveness timestamp.
    public func ingest(_ record: CKRecord) {
        guard let csc = ConnectionStateChangeRecord(record) else { return }
        // v7: the counter is a record FIELD (record names are now unique per
        // send), decoded into `csc.counter` — no more name parsing.
        ingest(csc, counter: csc.counter)
    }

    public func ingest(_ csc: ConnectionStateChangeRecord, counter overrideCounter: Int? = nil) {
        let counter = overrideCounter ?? csc.counter
        let macId = csc.macId
        let iosId = csc.iosDeviceId

        // v7: promptless same-iCloud connect. The Mac tapped this iPhone in the
        // picker and published CSC{accepted, origin:mac}. Connect directly — no
        // prompt — by creating/activating the local row, then echo
        // CSC{accepted, origin:ios} so the Mac stays confirmed. Handle before
        // the "existing connection" guard so a brand-new connection isn't dropped.
        if (csc.state == ConnectionStateChangeRecord.State.accepted.rawValue
            || csc.state == ConnectionStateChangeRecord.State.active.rawValue),
           csc.origin == ConnectionStateChangeRecord.Origin.mac.rawValue,
           csc.shareURLString == nil,            // same-iCloud (no CKShare)
           iosId == IosDeviceId.current,
           !ConnectionStore.shared.connections.contains(where: {
               $0.macDeviceId == macId && $0.iosDeviceId == iosId && $0.status == .active
           }) {
            IOSPairingCoordinator.shared.connectFromMacInitiated(macId: macId, counter: counter)
            return
        }

        // v6 legacy: inbound same-iCloud pairing REQUEST from a Mac (prompt
        // flow). Retained for older Macs; v7 Macs send `.accepted` directly.
        if csc.state == ConnectionStateChangeRecord.State.requested.rawValue,
           csc.origin == ConnectionStateChangeRecord.Origin.mac.rawValue,
           iosId == IosDeviceId.current {
            let macName = MacStatusStore.shared.byMacId[macId]?.name ?? "Mac"
            IOSPairingCoordinator.shared.ingestInboundRequest(macId: macId, macName: macName)
            return
        }

        // Reinstall reconciliation: if the inbound iosDeviceId is
        // different from a Connection we already have for this Mac,
        // and the CSC's `oldIosDeviceId` matches our row's current
        // iosDeviceId, adopt the new one.
        if let existing = ConnectionStore.shared.connections.first(where: {
            $0.macDeviceId == macId && $0.iosDeviceId == csc.oldIosDeviceId
        }) {
            ConnectionStore.shared.reattachWithNewIosId(
                connectionId: existing.id,
                newIosDeviceId: iosId
            )
            SyncTelemetry.shared.record(.stateUpdate, side: .ios,
                                        detail: "csc reinstall-detected (mac=\(macId))")
        }

        guard var connection = ConnectionStore.shared.connections.first(where: {
            $0.macDeviceId == macId && $0.iosDeviceId == iosId
        }) else {
            // Unknown connection — this can happen if the iOS app is
            // brand-new and a CSC from the Mac's perspective arrived
            // before any MacStatus heart-beat. Drop silently; the
            // (v6: no auto-attach — a connection only exists after an
            // explicit Mac-initiated request + iPhone accept.)
            logger.debug("csc: no matching Connection for mac=\(macId, privacy: .public) ios=\(iosId, privacy: .public) — dropping")
            return
        }
        // v5.1: ignore our own outgoing CSCs. The iOS app's public-DB
        // subscription also picks up the CSC{pending,origin:ios}
        // we just wrote. We only care about responses from the Mac.
        if csc.origin == ConnectionStateChangeRecord.Origin.ios.rawValue {
            logger.debug("csc: ignoring own outgoing (origin=ios) — dropping")
            return
        }
        // Reject out-of-order replays. A late CSC with counter <=
        // current must NOT regress the local state.
        guard counter > connection.stateChangeCounter else {
            logger.debug("csc: out-of-order replay (counter=\(counter)) for mac=\(macId, privacy: .public) — dropping")
            return
        }
        let state = ConnectionStateChangeRecord.State(rawValue: csc.state) ?? .accepted
        connection.stateChangeCounter = counter
        switch state {
        case .accepted, .active:
            connection.status = .active
            connection.lastSyncAt = csc.timestamp
            if connection.removedAt != nil { connection.removedAt = nil }
            // v5.1: notify the AddMacView's "Same iCloud" pair
            // sheet so it can dismiss with the success celebration.
            // Only fire for a row that was previously .pending
            // (i.e., we just got the Mac's response to our
            // CSC{pending}); existing cross-account rows don't
            // need this notification.
            if csc.origin == ConnectionStateChangeRecord.Origin.mac.rawValue {
                NotificationCenter.default.post(
                    name: .connectionPairAccepted,
                    object: nil,
                    userInfo: ["macId": macId, "iosId": iosId]
                )
            }
        case .suspended:
            connection.status = .suspended
        case .removed:
            // v5.3: hard-delete. The Mac told us it disconnected
            // (either via the user's swipe-to-delete on the Mac,
            // or via a Mac-initiated "Forget this iPhone"). The
            // old tombstone behaviour was the source of the
            // "row resurrects on refresh" bug. Mirror the Mac's
            // hard-delete locally.
            let toDelete = connection
            // v7: no suppression — the Mac stays discoverable for an explicit re-pair.
            // Drop the local row; the single shared-DB engine needs no
            // per-connection teardown (v6 consolidation).
            ConnectionStore.shared.remove(id: toDelete.id)
            Task { await LocalStore.shared.clearMacData(macId: toDelete.macDeviceId) }
            ConnectionNotifier.shared.notifyDisconnected(
                macName: MacStatusStore.shared.byMacId[toDelete.macDeviceId]?.name
            )
            return
        case .reinstallDetected:
            // Handled above via the oldIosDeviceId path.
            break
        case .pending:
            // Mac wrote a CSC{pending,origin:mac} — this would only
            // happen if a future reverse flow asks the iOS to confirm.
            // v5.1 doesn't do this, but keep the case explicit so
            // a future v6 doesn't silently mis-handle it.
            break
        case .denied:
            // v5.1: Mac denied a same-iCloud pair request. Hard-delete
            // the .pending row and notify the AddMacView so it can
            // dismiss with an error toast. v5.3 same hard-delete
            // semantics as .removed.
            let toDelete = connection
            ConnectionStore.shared.remove(id: toDelete.id)
            Task { await LocalStore.shared.clearMacData(macId: toDelete.macDeviceId) }
            NotificationCenter.default.post(
                name: .connectionPairDenied,
                object: nil,
                userInfo: ["macId": macId, "iosId": iosId]
            )
            return
        case .requested:
            // v6: a Mac is requesting to pair (same-iCloud flow). Inbound
            // requests for NEW rows are handled by `ingestInboundRequest`
            // before this point; if we reach here with an existing row,
            // mark it pending-on-phone so the Accept prompt re-surfaces.
            connection.status = .pendingOnPhone
            ConnectionStore.shared.upsert(connection)
            return
        }
        // If we're the iOS side and the inbound is from the Mac, the
        // Mac has acknowledged our pair. Back-fill shareAcceptedAt
        // on cross-account rows.
        if csc.origin == ConnectionStateChangeRecord.Origin.mac.rawValue,
           case .ckShare = connection.route,
           connection.shareAcceptedAt == nil {
            connection.shareAcceptedAt = csc.timestamp
        }
        ConnectionStore.shared.upsert(connection)
        SyncTelemetry.shared.record(.stateUpdate, side: .ios,
                                    detail: "csc ingest state=\(state.rawValue) mac=\(macId)")
    }
}

// MARK: - Pending record cache (used by the private engine delegate)

@MainActor
final class CSCPendingCache {
    static let shared = CSCPendingCache()
    private init() {}

    enum Route { case privateDB, sharedDB }
    private var pending: [String: (CKRecord, Route)] = [:]

    func put(_ r: CKRecord, route: Route) {
        pending[r.recordID.recordName] = (r, route)
    }

    func buildCKRecord(for recordID: CKRecord.ID) -> CKRecord? {
        guard let (stored, _) = pending[recordID.recordName] else { return nil }
        return stored
    }

    func didSave(_ record: CKRecord) {
        pending.removeValue(forKey: record.recordID.recordName)
    }

    /// Self-heal for a `serverRecordChanged` failure: merge our pending field
    /// values onto the server's copy (which carries the live etag) so the
    /// re-enqueued save is a clean UPDATE. (CSC names include a monotonic
    /// counter, so this is rare, but keep parity with the PeerStatus path.)
    func applyServerRecord(_ server: CKRecord) {
        let name = server.recordID.recordName
        if let (pendingRecord, route) = pending[name] {
            for key in pendingRecord.allKeys() { server[key] = pendingRecord[key] }
            pending[name] = (server, route)
        } else {
            pending[name] = (server, .privateDB)
        }
    }
}
