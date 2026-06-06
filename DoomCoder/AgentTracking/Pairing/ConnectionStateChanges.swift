// ConnectionStateChanges.swift — DoomCoder Mac
// v5: writer + observer for the cross-device state-change record
// (see `ConnectionStateChangeRecord` in DoomCoderCore). The Mac-side
// mirror of the iOS-side helper. The architecture is symmetrical:
//
//   ┌──────────────┐                                ┌──────────────┐
//   │  iOS side    │ ─── CSC{state, origin: ios} ─►│  Mac side    │
//   │              │ ◄── CSC{state, origin: mac} ─│              │
//   └──────────────┘                                └──────────────┘
//
// Both sides have a CKSyncEngine subscribed to DoomCoderZone (or,
// for cross-account CKShare, the shared zone owned by the Mac).
// When a CSC record is written, CloudKit sends an APNs silent push
// to the other device within 1-3s. The engine picks the record up,
// `ingest(_:)` runs on the receiving side, and `PairingStore` is
// updated + the UI re-renders.

import Foundation
import CloudKit
import OSLog
import DoomCoderCore

@MainActor
final class ConnectionStateChanges {
    static let shared = ConnectionStateChanges()

    private let container: CKContainer
    private let logger = Logger(subsystem: "com.doomcoder", category: "csc.mac")
    /// Per-shared-zone server record cache for direct writes from
    /// the Mac back to the iOS app's shared-DB subscription. Mirrors
    /// the iOS-side pattern. Keyed by record name.
    private var sharedDbServerCache: [String: CKRecord] = [:]

    private init(container: CKContainer = CKContainer(identifier: CloudKitConstants.containerIdentifier)) {
        self.container = container
    }

    // MARK: - Write path (the "I just transitioned" side)

    /// Publishes a state-change record to the other side. The Mac
    /// is always on the same Apple ID as its own private zone, so
    /// the private-DB path is used by default. Cross-account paths
    /// route through the shared DB.
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

        if case .ckShare(let ref) = connection.route, !ref.isSameAccount {
            await writeViaSharedDB(record: rec, counter: counter, ref: ref)
        } else {
            await writeViaPrivateEngine(record: rec, counter: counter)
        }
    }

    private func writeViaPrivateEngine(record: ConnectionStateChangeRecord, counter: Int) async {
        // The Mac's pusher is a write-only engine. It already
        // serialises singletons via ServerRecordCache; CSCs are
        // singletons in spirit so we keep a local cache for the
        // recordChangeTag preservation.
        let ck = record.toCKRecord(counter: counter)
        if let cached = sharedDbServerCache[ck.recordID.recordName] {
            for key in ck.allKeys() { cached[key] = ck[key] }
            CSCMacPendingCache.shared.put(cached, route: .privateDB)
        } else {
            CSCMacPendingCache.shared.put(ck, route: .privateDB)
        }
        let engine = CloudKitPusher.shared.engine
        guard let engine else {
            await writeDirectToPrivateDB(record: record, counter: counter)
            return
        }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(ck.recordID)])
        // Flush now instead of waiting on automaticallySync's indeterminate
        // schedule — a pairing CSC{requested} must reach the iPhone promptly.
        CloudKitPusher.shared.kickEngine()
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
        // The Mac owns the shared zone; writes from the Mac to the
        // shared zone go through its own private DB engine (the
        // participant writes through container.sharedCloudDatabase;
        // the owner writes through container.privateCloudDatabase
        // and the record is replicated). For our purposes the
        // private engine path with a cross-zone record works.
        let ck = record.toCKRecord(counter: counter)
        if let cached = sharedDbServerCache[ck.recordID.recordName] {
            for key in ck.allKeys() { cached[key] = ck[key] }
            CSCMacPendingCache.shared.put(cached, route: .sharedDB)
        } else {
            CSCMacPendingCache.shared.put(ck, route: .sharedDB)
        }
        let engine = CloudKitPusher.shared.engine
        guard let engine else {
            await writeDirectToSharedDB(record: record, counter: counter)
            return
        }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(ck.recordID)])
        CloudKitPusher.shared.kickEngine()
    }

    private func writeDirectToSharedDB(record: ConnectionStateChangeRecord, counter: Int) async {
        let ck = record.toCKRecord(counter: counter)
        let op = CKModifyRecordsOperation(recordsToSave: [ck], recordIDsToDelete: nil)
        op.savePolicy = .allKeys
        op.qualityOfService = .userInitiated
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            op.modifyRecordsResultBlock = { _ in cont.resume() }
            container.privateCloudDatabase.add(op)
        }
    }

    // MARK: - Read path (the "the other side transitioned" side)

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

        // Reinstall reconciliation: if the inbound iosDeviceId is
        // different from a Connection we already have for this Mac,
        // and the CSC's `oldIosDeviceId` matches our row's current
        // iosDeviceId, adopt the new one.
        if let existing = PairingStore.shared.connection(forIosDeviceId: csc.oldIosDeviceId ?? "")
           ?? PairingStore.shared.connections.first(where: { $0.macDeviceId == macId && $0.iosDeviceId == csc.oldIosDeviceId }) {
            if existing.iosDeviceId != iosId {
                var reconciled = existing
                reconciled.iosDeviceId = iosId
                reconciled.pairingOrigin = .reinstall
                reconciled.stateChangeCounter += 1
                reconciled.removedAt = nil
                reconciled.status = .active
                reconciled.lastSyncAt = csc.timestamp
                PairingStore.shared.upsert(reconciled)
                logger.notice("csc.mac: reinstall-detected adopted new iosId=\(iosId, privacy: .public)")
            }
        }

        // v5.2: CSC{accepted,origin=ios} is the AUTHORITATIVE
        // "this iOS device just paired" signal. We no longer drop
        // it when no matching row exists — the heart-beat can be
        // throttled or coalesced by APNs (Apple docs: "don't rely
        // on pushes for specific changes") so the previous
        // "next heart-beat will register the row" behaviour
        // left the Mac Connections tab empty for up to 60s and
        // sometimes forever. Create the row from the CSC itself.
        let stateForCreate = ConnectionStateChangeRecord.State(rawValue: csc.state) ?? .accepted
        if PairingStore.shared.connections.first(where: {
            $0.macDeviceId == macId && $0.iosDeviceId == iosId
        }) == nil,
           csc.origin == ConnectionStateChangeRecord.Origin.ios.rawValue,
           (stateForCreate == .accepted || stateForCreate == .active) {
            let id = Connection.implicitConnectionId(macId: macId, iosDeviceId: iosId)
            let new = Connection(
                id: id,
                macDeviceId: macId,
                iosDeviceId: iosId,
                route: .iCloud,
                status: .active,
                createdAt: csc.timestamp,
                lastSyncAt: csc.timestamp,
                ckShareRef: nil,
                pairingOrigin: .sameICloud,
                stateChangeCounter: max(counter, 1),
                shareAcceptedAt: csc.timestamp
            )
            PairingStore.shared.upsert(new)
            IosDeviceProfileCache.shared.insertPlaceholder(
                iosDeviceId: iosId,
                name: "iPhone"
            )
            // If this came from the same-iCloud code/QR flow, tear down the live
            // code now that a device has paired.
            MacPairingCoordinator.shared.stopSameICloudCode()
            logger.notice("csc.mac: v7 created row from CSC{accepted,origin=ios} for mac=\(macId, privacy: .public) ios=\(iosId, privacy: .public)")
        }

        guard var connection = PairingStore.shared.connections.first(where: {
            $0.macDeviceId == macId && $0.iosDeviceId == iosId
        }) else {
            // No matching connection and the state wasn't an
            // iOS-originated accepted/active (which we just
            // created above). For other states (.removed, .denied,
            // etc.) with no existing row, drop silently — the iOS
            // app's local store is the source of truth for those.
            logger.debug("csc.mac: no matching Connection for mac=\(macId, privacy: .public) ios=\(iosId, privacy: .public) state=\(csc.state) — dropping")
            return
        }
        // Reject out-of-order replays.
        guard counter > connection.stateChangeCounter else {
            logger.debug("csc.mac: out-of-order replay (counter=\(counter)) for mac=\(macId, privacy: .public) — dropping")
            return
        }
        let state = ConnectionStateChangeRecord.State(rawValue: csc.state) ?? .accepted
        connection.stateChangeCounter = counter
        switch state {
        case .accepted, .active:
            let wasActive = (connection.status == .active)
            connection.status = .active
            connection.lastSyncAt = csc.timestamp
            if connection.removedAt != nil { connection.removedAt = nil }
            if !wasActive {
                let name = IosDeviceProfileCache.shared.name(for: connection.iosDeviceId)
                NotificationDispatcher.shared.notifyDeviceConnected(name: name)
            }
        case .suspended:
            connection.status = .suspended
        case .removed:
            // v5.3: hard-delete. The iOS app told us it
            // disconnected. Drop the row immediately instead
            // of tombstoning it for 30 days. The old
            // tombstone-on-remove behaviour was the source of
            // the "row resurrects on refresh" bug the user
            // reported: the Mac would keep showing the row
            // with a "Removed 40s ago" pill until
            // purgeTombstones ran 30 days later.
            let toDelete = connection
            let name = IosDeviceProfileCache.shared.name(for: toDelete.iosDeviceId)
            // v7: no suppression — the iPhone stays discoverable in the picker.
            PairingStore.shared.hardRemove(connectionId: toDelete.id)
            NotificationDispatcher.shared.notifyDeviceDisconnected(name: name)
            return
        case .reinstallDetected:
            break  // handled above
        case .pending:
            // Legacy v5.1 state — no longer produced (the iPhone no longer
            // initiates same-iCloud requests). Kept for decode-compat; no-op.
            break
        case .denied:
            // Mac doesn't receive .denied CSCs (only the iOS
            // app does). Same defensive no-op.
            break
        case .requested:
            // v6: CSC{requested} is written by the MAC (initiator) into
            // the public DB for the iPhone to accept. The Mac never
            // ingests its own request as a zone state change — no-op.
            break
        }
        if csc.origin == ConnectionStateChangeRecord.Origin.ios.rawValue,
           case .ckShare = connection.route,
           connection.shareAcceptedAt == nil {
            connection.shareAcceptedAt = csc.timestamp
        }
        PairingStore.shared.upsert(connection)
    }
}

// MARK: - Pending record cache (used by the Mac private engine delegate)

@MainActor
final class CSCMacPendingCache {
    static let shared = CSCMacPendingCache()
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
}
