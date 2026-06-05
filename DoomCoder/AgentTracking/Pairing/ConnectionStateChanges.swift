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
        ingest(csc)
    }

    // MARK: - v5.1 same-iCloud gated response

    /// v5.1: called by the Mac's PendingPairRequestSheet when
    /// the user clicks Allow. Creates a real .iCloud Connection
    /// in PairingStore, publishes CSC{accepted,origin:mac} back
    /// to the iOS app, and inserts a placeholder profile so the
    /// Mac's Connections tab has a name to render immediately
    /// (the iOS app's real name arrives within 60s on the next
    /// heart-beat).
    public func approvePendingRequest(
        macId: String,
        iosDeviceId: String,
        iosUserRecordID: String?
    ) async {
        // Authoritative same-iCloud check via the canonical
        // non-deprecated Apple API: compare the iOS-supplied
        // iosUserRecordID to the Mac's own userRecordID(). When
        // they match, the iOS device is on the same iCloud
        // account and the user already opted in by clicking
        // Allow. We don't need a CKShare — the existing private
        // DB subscription is enough.
        let sameICloud: Bool
        if let iosUserRecordID, !iosUserRecordID.isEmpty {
            let macUserRecordName: String
            do {
                macUserRecordName = try await container.userRecordID().recordName
            } catch {
                macUserRecordName = ""
            }
            sameICloud = !macUserRecordName.isEmpty && macUserRecordName == iosUserRecordID
        } else {
            sameICloud = false
        }

        let id = Connection.implicitConnectionId(macId: macId, iosDeviceId: iosDeviceId)
        let new = Connection(
            id: id,
            macDeviceId: macId,
            iosDeviceId: iosDeviceId,
            route: .iCloud,
            status: .active,
            createdAt: Date(),
            lastSyncAt: Date(),
            ckShareRef: nil,
            pairingOrigin: .auto,
            stateChangeCounter: 1,
            shareAcceptedAt: Date()
        )
        PairingStore.shared.upsert(new)
        // Insert a placeholder so the Mac's Connections tab has
        // a name to render immediately. The real name arrives
        // on the next PeerStatus heart-beat.
        IosDeviceProfileCache.shared.insertPlaceholder(
            iosDeviceId: iosDeviceId,
            name: sameICloud ? "iPhone" : "iPhone (different iCloud)"
        )

        // Publish CSC{accepted,origin:mac} back to the iOS app
        // via the public DB so the iOS app can dismiss the
        // pair sheet with the success celebration.
        let accepted = ConnectionStateChangeRecord(
            macId: macId,
            iosDeviceId: iosDeviceId,
            state: ConnectionStateChangeRecord.State.accepted.rawValue,
            timestamp: Date(),
            origin: ConnectionStateChangeRecord.Origin.mac.rawValue,
            routeTag: "iCloud",
            shareURLString: nil,
            routeAccountEmail: nil,
            oldIosDeviceId: nil,
            iosUserRecordID: nil
        )
        // Direct write — no engine required. The iOS app's
        // public-DB subscription picks it up in 1-3s.
        let ck = accepted.toCKRecord(counter: 1)
        // The CSC targets the public DB default zone. Construct
        // an explicit recordID to avoid the private-DB default.
        let publicRecordID = CKRecord.ID(
            recordName: ck.recordID.recordName,
            zoneID: CKRecordZone.ID(zoneName: "DoomCoderZone", ownerName: CKCurrentUserDefaultName)
        )
        let publicRec = CKRecord(
            recordType: CloudKitConstants.RecordType.connectionStateChange,
            recordID: publicRecordID
        )
        publicRec["macId"] = macId as CKRecordValue
        publicRec["iosDeviceId"] = iosDeviceId as CKRecordValue
        publicRec["state"] = "accepted" as CKRecordValue
        publicRec["timestamp"] = Date() as CKRecordValue
        publicRec["origin"] = "mac" as CKRecordValue
        publicRec["routeTag"] = "iCloud" as CKRecordValue
        publicRec["schemaVersion"] = CloudKitConstants.schemaVersion as CKRecordValue
        let op = CKModifyRecordsOperation(recordsToSave: [publicRec], recordIDsToDelete: nil)
        op.savePolicy = .allKeys
        op.qualityOfService = .userInitiated
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            op.modifyRecordsResultBlock = { _ in cont.resume() }
            container.publicCloudDatabase.add(op)
        }
    }

    /// v5.1: called by the Mac's PendingPairRequestSheet when
    /// the user clicks Deny. Publishes CSC{denied,origin:mac}
    /// back to the iOS app so the pair sheet dismisses with an
    /// error toast. No Connection is created.
    public func denyPendingRequest(
        macId: String,
        iosDeviceId: String,
        iosUserRecordID: String?
    ) async {
        let denied = ConnectionStateChangeRecord(
            macId: macId,
            iosDeviceId: iosDeviceId,
            state: ConnectionStateChangeRecord.State.denied.rawValue,
            timestamp: Date(),
            origin: ConnectionStateChangeRecord.Origin.mac.rawValue,
            routeTag: "iCloud",
            shareURLString: nil,
            routeAccountEmail: nil,
            oldIosDeviceId: nil,
            iosUserRecordID: nil
        )
        let ck = denied.toCKRecord(counter: 1)
        let publicRecordID = CKRecord.ID(
            recordName: ck.recordID.recordName,
            zoneID: CKRecordZone.ID(zoneName: "DoomCoderZone", ownerName: CKCurrentUserDefaultName)
        )
        let publicRec = CKRecord(
            recordType: CloudKitConstants.RecordType.connectionStateChange,
            recordID: publicRecordID
        )
        publicRec["macId"] = macId as CKRecordValue
        publicRec["iosDeviceId"] = iosDeviceId as CKRecordValue
        publicRec["state"] = "denied" as CKRecordValue
        publicRec["timestamp"] = Date() as CKRecordValue
        publicRec["origin"] = "mac" as CKRecordValue
        publicRec["routeTag"] = "iCloud" as CKRecordValue
        publicRec["schemaVersion"] = CloudKitConstants.schemaVersion as CKRecordValue
        let op = CKModifyRecordsOperation(recordsToSave: [publicRec], recordIDsToDelete: nil)
        op.savePolicy = .allKeys
        op.qualityOfService = .userInitiated
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            op.modifyRecordsResultBlock = { _ in cont.resume() }
            container.publicCloudDatabase.add(op)
        }
    }

    public func ingest(_ csc: ConnectionStateChangeRecord) {
        let counter = ConnectionStateChangeRecord
            .counterFromRecordName(csc.recordName(counter: 0))
            ?? 0
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
                pairingOrigin: .auto,
                stateChangeCounter: max(counter, 1),
                shareAcceptedAt: csc.timestamp
            )
            PairingStore.shared.upsert(new)
            IosDeviceProfileCache.shared.insertPlaceholder(
                iosDeviceId: iosId,
                name: "iPhone"
            )
            logger.notice("csc.mac: v5.2 created row from CSC{accepted,origin=ios} for mac=\(macId, privacy: .public) ios=\(iosId, privacy: .public)")
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
            connection.status = .active
            connection.lastSyncAt = csc.timestamp
            if connection.removedAt != nil { connection.removedAt = nil }
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
            PairingStore.shared.hardRemove(connectionId: toDelete.id)
            return
        case .reinstallDetected:
            break  // handled above
        case .pending:
            // Mac-side CSC ingest path doesn't see .pending CSCs
            // (those are on the public DB and handled by
            // PendingPairRequestSubscription). If we do see one
            // here (e.g., a future v6 cross-DB routing), no-op
            // is the safe behaviour.
            break
        case .denied:
            // Mac doesn't receive .denied CSCs (only the iOS
            // app does). Same defensive no-op.
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
