// IOSPairingCoordinator.swift — DoomCoder Companion
// Handles the iOS side of CKShare-based pairing. The flow is:
//   1. iPhone scans QR / opens doomcoder:// URL containing a CKShare URL
//   2. PairURLHandler parses the URL and hands it to this coordinator
//   3. Coordinator calls CKContainer.accept([shareMeta]) — iOS shows the
//      system share-acceptance sheet (Apple-provided, not customizable)
//   4. On success, the iOS app now has access to the Mac's private DB zone
//      via the accepted share. We register a ShareSyncEngine so we can
//      fetch records from that shared zone.
//   5. The Connection is persisted as .active so the UI can show it.

import Foundation
import CloudKit
import Combine
import UIKit
import DoomCoderCore

@MainActor
@Observable
final class IOSPairingCoordinator {

    static let shared = IOSPairingCoordinator()

    enum Phase: Equatable, Sendable {
        case idle
        case awaitingSystemAcceptance(shareURL: URL, containerIdentifier: String)
        case accepting(shareURL: URL, containerIdentifier: String)
        case active(Connection)
        case failed(ConnectionError)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastError: ConnectionError?
    public var presentScanner = false
    public var presentSuccess = false
    public var successMessage: String = ""

    private let container: CKContainer

    public init(
        container: CKContainer = CKContainer(identifier: CloudKitConstants.containerIdentifier)
    ) {
        self.container = container
    }

    // MARK: - Reset

    public func reset() {
        guard case .failed = phase else { return }
        phase = .idle
        lastError = nil
    }

    // MARK: - Same-Apple-ID auto-attach (v5)

    /// Invoked by `AutoPairDiscovery` the first time a MacStatus
    /// record arrives from a Mac on the same iCloud account as the
    /// iOS device. Creates a real `Connection` row (so the device
    /// shows up in the Dashboard devices section, in diagnostics,
    /// in MacSwitcher, and so on) and a CSC{accepted, origin:ios}
    /// so the Mac learns about the new pair within 1-3s.
    ///
    /// The deterministic id from `implicitConnectionId(macId:iosDeviceId:)`
    /// guarantees idempotency: a second MacStatus heart-beat within
    /// 100ms upserts the same row instead of creating a duplicate.
    public func autoAttach(macStatus: MacStatusRecord) async {
        let macId = macStatus.macId
        let iosId = IosDeviceId.current

        // Deterministic id: same (macId, iosId) → same row.
        let id = Connection.implicitConnectionId(macId: macId, iosDeviceId: iosId)
        if let existing = ConnectionStore.shared.connections.first(where: { $0.id == id }) {
            // Already attached — just refresh liveness.
            var updated = existing
            updated.status = .active
            updated.lastSyncAt = macStatus.lastSeen
            ConnectionStore.shared.upsert(updated)
            return
        }

        let connection = Connection(
            id: id,
            macDeviceId: macId,
            iosDeviceId: iosId,
            route: .iCloud,
            status: .active,
            createdAt: Date(),
            lastSyncAt: macStatus.lastSeen,
            ckShareRef: nil,
            pairingOrigin: .auto,
            stateChangeCounter: 1
        )
        ConnectionStore.shared.upsert(connection)
        // Wake the Mac side via the dedicated state-change record.
        // Belt-and-braces: the per-60s PeerStatus heart-beat will
        // also land, but the CSC arrives in 1-3s and gives the
        // user-facing Mac Connections tab a snappy "iPhone connected"
        // update.
        await ConnectionStateChanges.shared.publish(
            state: .accepted,
            for: connection,
            origin: .ios
        )
        // Mirror in the success-banner state so a user who happens
        // to have AddMacView open sees the celebration.
        successMessage = "Paired with \(macStatus.name) automatically (same Apple ID)"
        presentSuccess = true
        phase = .active(connection)
    }

    // MARK: - URL entry points

    /// Called by AppDelegate when doomcoder://pair?ckShareURL=... arrives.
    public func handle(pairURL: URL) async {
        guard let parsed = PairURLHandler.parse(url: pairURL) else {
            let err = ConnectionError.invalidPairingCode
            lastError = err
            phase = .failed(err)
            return
        }
        // doomcoder:// URLs come from share-link taps (Messages,
        // AirDrop, Mail). Distinguish from the QR scan path by
        // inspecting the embedded link — the QR encodes the same
        // URL but came from a scan, not a paste. The caller
        // already knows; here we mark it as `.link`.
        await accept(
            shareURL: parsed.shareURL,
            containerIdentifier: parsed.containerIdentifier,
            origin: .link
        )
    }

    /// Called by the QR scanner with the raw scanned string.
    public func handle(scannedString: String) async {
        // QR may contain either a doomcoder:// URL or a raw CKShare URL.
        if let url = URL(string: scannedString), url.scheme == "doomcoder" {
            // The QR on the Mac encodes a doomcoder:// URL with the
            // share URL inside it; mark this as `.qr`.
            guard let parsed = PairURLHandler.parse(url: url) else {
                let err = ConnectionError.invalidPairingCode
                lastError = err
                phase = .failed(err)
                return
            }
            await accept(
                shareURL: parsed.shareURL,
                containerIdentifier: parsed.containerIdentifier,
                origin: .qr
            )
        } else if let url = URL(string: scannedString), url.host == "www.icloud.com" {
            // Some QR generators encode the raw CKShare URL.
            await accept(
                shareURL: url,
                containerIdentifier: CloudKitConstants.containerIdentifier,
                origin: .qr
            )
        } else {
            let err = ConnectionError.invalidPairingCode
            lastError = err
            phase = .failed(err)
        }
    }

    // MARK: - Share acceptance

    private func accept(
        shareURL: URL,
        containerIdentifier: String,
        origin: PairingOrigin
    ) async {
        phase = .awaitingSystemAcceptance(shareURL: shareURL, containerIdentifier: containerIdentifier)
        do {
            // Fetch share metadata — this tells us who the owner is and whether
            // the current user is already a participant.
            let metadata: CKShare.Metadata
            do {
                metadata = try await container.shareMetadata(for: shareURL)
            } catch {
                throw mapCKError(error, context: .metadata)
            }

            let ownerRecordName = metadata.ownerIdentity.userRecordID?.recordName ?? ""

            // Scenario A — Same iCloud account:
            //   participantRole == .owner means the current user IS the owner.
            //   CloudKit rejects .accept() for owners ("owner participant tried to
            //   accept share"). The iPhone already has full access to the private zone
            //   — skip .accept() and use CompanionSyncEngine (private DB) instead of
            //   ShareSyncEngineRegistry (shared DB).
            let isOwner = metadata.participantRole == .owner

            // Scenario B — Already accepted (re-scan same QR or code re-entry):
            //   Skip .accept() to avoid a redundant round-trip.
            let alreadyAccepted = metadata.participantStatus == .accepted

            if !isOwner && !alreadyAccepted {
                phase = .accepting(shareURL: shareURL, containerIdentifier: containerIdentifier)
                do {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        container.accept(metadata) { _, error in
                            if let error { cont.resume(throwing: error) }
                            else { cont.resume() }
                        }
                    }
                } catch {
                    // Defensive recovery: if the server still rejects with
                    // "owner tried to accept", treat as same-account silently.
                    if let ck = error as? CKError,
                       ck.code == .serverRejectedRequest,
                       (ck.localizedDescription.lowercased().contains("owner") ||
                        ck.localizedDescription.lowercased().contains("participant")) {
                        // Fall through to persistConnection with isSameAccount = true
                        try await persistConnection(
                            shareURL: shareURL,
                            containerIdentifier: containerIdentifier,
                            ownerRecordName: ownerRecordName,
                            isSameAccount: true,
                            origin: origin
                        )
                        return
                    }
                    throw mapCKError(error, context: .accept)
                }
            }

            try await persistConnection(
                shareURL: shareURL,
                containerIdentifier: containerIdentifier,
                ownerRecordName: ownerRecordName,
                isSameAccount: isOwner,
                origin: origin
            )
        } catch let err as ConnectionError {
            lastError = err
            phase = .failed(err)
        } catch {
            let wrapped = ConnectionError.shareAcceptanceFailed(error.localizedDescription)
            lastError = wrapped
            phase = .failed(wrapped)
        }
    }

    private enum AcceptContext { case metadata, accept }

    private func mapCKError(_ error: Error, context: AcceptContext) -> ConnectionError {
        guard let ck = error as? CKError else {
            return .shareAcceptanceFailed(error.localizedDescription)
        }
        switch ck.code {
        case .networkUnavailable, .networkFailure:
            return .shareAcceptanceFailed("No internet connection. Check your network and try again.")
        case .notAuthenticated:
            return .iCloudUnavailable
        case .permissionFailure:
            return .shareAcceptanceFailed("You don't have permission to access this share.")
        case .unknownItem:
            return context == .metadata
                ? .shareAcceptanceFailed("This pairing link has expired or been revoked. Ask the Mac to generate a new one.")
                : .shareAcceptanceFailed(ck.localizedDescription)
        case .userDeletedZone:
            return .shareRevoked
        case .alreadyShared:
            return .alreadyPaired
        case .requestRateLimited:
            return .shareAcceptanceFailed("iCloud is rate-limiting requests. Wait a moment and try again.")
        case .zoneBusy:
            return .shareAcceptanceFailed("iCloud is busy. Try again in a moment.")
        case .serviceUnavailable:
            return .shareAcceptanceFailed("iCloud is unavailable right now. Try again later.")
        case .serverRejectedRequest:
            return .shareAcceptanceFailed("The server rejected this pairing request. Try scanning the QR again.")
        default:
            return .shareAcceptanceFailed("iCloud error \(ck.code.rawValue): \(ck.localizedDescription)")
        }
    }

    private func persistConnection(
        shareURL: URL,
        containerIdentifier: String,
        ownerRecordName: String,
        isSameAccount: Bool,
        origin: PairingOrigin
    ) async throws {
        // Same-account connections use the sentinel so ShareSyncEngineRegistry
        // and PeerStatusPublisher know to use the private-DB path instead.
        let ref: CKShareRef = isSameAccount
            ? .sameAccount(shareURL: shareURL, containerIdentifier: containerIdentifier)
            : CKShareRef(shareURL: shareURL, ownerRecordName: ownerRecordName, containerIdentifier: containerIdentifier)

        // Deterministic id keyed on share URL — re-scanning the same QR upserts
        // the existing row rather than creating a duplicate.
        let id = Connection.deterministicId(for: .ckShare(ref))
        let macId = MacStatusStore.shared.primary?.macId ?? ""

        if let existing = ConnectionStore.shared.connections.first(where: { $0.id == id }) {
            var refreshed = existing
            refreshed.status = .active
            refreshed.lastSyncAt = Date()
            if !macId.isEmpty { refreshed.macDeviceId = macId }
            if refreshed.shareAcceptedAt == nil { refreshed.shareAcceptedAt = Date() }
            ConnectionStore.shared.upsert(refreshed)
            registerSyncEngine(for: refreshed, isSameAccount: isSameAccount)
            // Echo an accepted CSC so the Mac learns within 1-3s
            // (instead of waiting for the 60s PeerStatus heart-beat
            // or the CKShare-change delegate callback).
            await ConnectionStateChanges.shared.publish(
                state: .accepted,
                for: refreshed,
                origin: .ios
            )
            // Use the Mac's actual name if we have it; fall back to
            // a generic "Paired" line.
            let macName = MacStatusStore.shared.byMacId[refreshed.macDeviceId]?.name
            successMessage = macName.map { "Paired with \($0)" } ?? "Paired with this Mac"
            presentSuccess = true
            phase = .active(refreshed)
            return
        }

        let connection = Connection(
            id: id,
            macDeviceId: macId,
            iosDeviceId: IosDeviceId.current,
            route: .ckShare(ref),
            status: .active,
            lastSyncAt: Date(),
            ckShareRef: ref,
            pairingOrigin: origin,
            stateChangeCounter: 1,
            shareAcceptedAt: Date()
        )
        ConnectionStore.shared.upsert(connection)
        registerSyncEngine(for: connection, isSameAccount: isSameAccount)
        // Echo an accepted CSC so the Mac learns within 1-3s.
        await ConnectionStateChanges.shared.publish(
            state: .accepted,
            for: connection,
            origin: .ios
        )
        let macName = MacStatusStore.shared.byMacId[connection.macDeviceId]?.name
        successMessage = macName.map { "Paired with \($0)" } ?? "Paired with this Mac"
        presentSuccess = true
        phase = .active(connection)
    }

    private func registerSyncEngine(for connection: Connection, isSameAccount: Bool) {
        if isSameAccount {
            Task { await CompanionSyncEngine.shared.fetchChanges() }
        } else {
            ShareSyncEngineRegistry.shared.register(connection: connection)
        }
        // Belt-and-braces: a PeerStatus heart-beat lands within
        // 60s regardless, so the Mac always has at least one
        // signal path to discover the iOS device.
        PeerStatusPublisher.shared.publishNow(force: true)
    }

    // MARK: - Code-based pairing

    /// Looks up a 6-char pairing code in the CloudKit public database and
    /// accepts the share whose URL is stored there. Called when the user
    /// types the code shown on the Mac instead of scanning the QR.
    public func resolveCode(_ code: String) async {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard cleaned.count == 6 else {
            let err = ConnectionError.invalidPairingCode
            lastError = err
            phase = .failed(err)
            return
        }
        do {
            let recordID = CKRecord.ID(recordName: cleaned)
            let record: CKRecord
            do {
                record = try await container.publicCloudDatabase.record(for: recordID)
            } catch {
                throw ConnectionError.invalidPairingCode
            }
            if let expiresAt = record["expiresAt"] as? Date, Date() > expiresAt {
                throw ConnectionError.pairingCodeExpired
            }
            guard let shareURLString = record["shareURL"] as? String,
                  let shareURL = URL(string: shareURLString) else {
                throw ConnectionError.invalidPairingCode
            }
            await accept(
                shareURL: shareURL,
                containerIdentifier: CloudKitConstants.containerIdentifier,
                origin: .code
            )
        } catch let err as ConnectionError {
            lastError = err
            phase = .failed(err)
        } catch {
            let err = ConnectionError.invalidPairingCode
            lastError = err
            phase = .failed(err)
        }
    }

    // MARK: - Same-iCloud discoverable list (v5.1)

    /// v5.1: called when the iOS user taps a Mac in the "Same iCloud"
    /// discoverable list. Writes a CSC{pending,origin:ios} to the
    /// PUBLIC database (so the Mac can fetch it via its own public-DB
    /// subscription — see `DiscoverableMacSubscription`'s mirror on
    /// the Mac side) and sets `iosUserRecordID` so the Mac can verify
    /// same-iCloud via the canonical `CKRecord.creatorUserRecordID`
    /// comparison.
    ///
    /// This is a "request pending approval" — the Mac user has to
    /// click Allow in the PendingPairRequestSheet before a real
    /// Connection is created. The iOS app waits for the Mac's
    /// CSC{accepted,origin:mac} or CSC{denied,origin:mac} response.
    public func requestPairFromDiscoverableMac(_ mac: DiscoverableMacRecord) async {
        let iosId = IosDeviceId.current
        // Build a placeholder Connection. The id is deterministic
        // so when the Mac allows and writes a real Connection, both
        // sides collide on the same id.
        let id = Connection.implicitConnectionId(macId: mac.macId, iosDeviceId: iosId)
        let placeholder = Connection(
            id: id,
            macDeviceId: mac.macId,
            iosDeviceId: iosId,
            route: .iCloud,
            status: .pending,
            createdAt: Date(),
            lastSyncAt: nil,
            ckShareRef: nil,
            pairingOrigin: .auto,
            stateChangeCounter: 1
        )
        ConnectionStore.shared.upsert(placeholder)

        // Capture the iOS app's own user record name. Without
        // this the Mac can't classify the request. Falls back to
        // an empty string if the iOS user isn't signed in to
        // iCloud — the Mac still gets the CSC, just without
        // the verification hint.
        let iosUserRecordID: String
        do {
            iosUserRecordID = try await container.userRecordID().recordName
        } catch {
            iosUserRecordID = ""
        }

        // Write a CSC{pending,origin:ios} directly to the
        // public DB. No engine required; this is a tiny
        // singleton-style write.
        let counter = placeholder.stateChangeCounter
        let rec = ConnectionStateChangeRecord(
            macId: mac.macId,
            iosDeviceId: iosId,
            state: ConnectionStateChangeRecord.State.pending.rawValue,
            timestamp: Date(),
            origin: ConnectionStateChangeRecord.Origin.ios.rawValue,
            routeTag: "iCloud",
            shareURLString: nil,
            routeAccountEmail: nil,
            oldIosDeviceId: nil
        )
        let ck = rec.toCKRecord(counter: counter)
        // The public-DB record is in the default zone of the
        // public DB; we don't need to set the zoneID — the
        // initializer already uses the public default. Actually
        // — `toCKRecord(counter:)` uses CKCurrentUserDefaultName
        // which on a public-DB write would resolve to nil. We
        // need a public-DB-targeted record. Inline a tiny helper
        // so we can use the public default zone.
        let publicRecordID = CKRecord.ID(
            recordName: ck.recordID.recordName,
            zoneID: CKRecordZone.ID(zoneName: "DoomCoderZone", ownerName: CKCurrentUserDefaultName)
        )
        let publicRec = CKRecord(
            recordType: CloudKitConstants.RecordType.connectionStateChange,
            recordID: publicRecordID
        )
        publicRec["macId"] = mac.macId as CKRecordValue
        publicRec["iosDeviceId"] = iosId as CKRecordValue
        publicRec["state"] = "pending" as CKRecordValue
        publicRec["timestamp"] = Date() as CKRecordValue
        publicRec["origin"] = "ios" as CKRecordValue
        publicRec["routeTag"] = "iCloud" as CKRecordValue
        publicRec["iosUserRecordID"] = iosUserRecordID as CKRecordValue
        publicRec["schemaVersion"] = CloudKitConstants.schemaVersion as CKRecordValue

        let op = CKModifyRecordsOperation(recordsToSave: [publicRec], recordIDsToDelete: nil)
        op.savePolicy = .allKeys
        op.qualityOfService = .userInitiated
        op.modifyRecordsResultBlock = { [weak self] result in
            if case .failure(let err) = result {
                Task { @MainActor [weak self] in
                    self?.lastError = ConnectionError.unknown("Couldn't send pair request: \(err.localizedDescription)")
                    self?.phase = .failed(ConnectionError.unknown(err.localizedDescription))
                }
            } else {
                // v5.1: belt-and-braces — schedule a one-shot
                // fetch of the public-DB CSCs so the iOS app
                // picks up the Mac's response even if the
                // silent push hasn't arrived. Catches the
                // 60s-throttled APNs edge case.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    await DiscoverableMacSubscription.shared.fetchPublicCSCs()
                }
            }
        }
        container.publicCloudDatabase.add(op)

        // The Mac will pick this up within 1-3s via its own
        // public-DB CKQuerySubscription and post a CSC{accepted}
        // or CSC{denied} back. The iOS app observes that CSC via
        // the existing ConnectionStateChanges.ingest path.
    }

    // MARK: - Removal

    /// v5.3: hard-delete the connection on BOTH sides. The user
    /// expects the row to disappear the moment they tap
    /// Disconnect — not turn into a tombstone, not come back on
    /// the next heart-beat, not require a 30-day wait. The flow:
    ///   1. Bump counter + write CSC{removed,origin=ios} so the
    ///      Mac hard-deletes its side within 1-3s via the
    ///      silent-push path.
    ///   2. Hard-delete locally. The tombstone-on-remove behaviour
    ///      (v5) was the source of the "row resurrects on
    ///      refresh" bug: a 30s later heart-beat would arrive,
    ///      AutoPairDiscovery would NOT re-attach (because the
    ///      .removed row was still in the list), but the row
    ///      would re-render as "Removed 40 seconds ago" until
    ///      purgeTombstones ran 30 days later. That was the
    ///      correct semantics for a re-pair window but the wrong
    ///      semantics for an explicit user-driven disconnect.
    ///   3. Drop the per-Mac sync engine. Same-account auto-attach
    ///      remains disabled for this Mac for the 5-minute
    ///      cooldown (in case the user just hit Disconnect by
    ///      accident and immediately wants to re-pair — they can
    ///      wait it out, or hit "Re-pair" in the agent list
    ///      which is unaffected by the cooldown).
    public func remove(connection: Connection) async {
        var snapshot = connection
        snapshot.stateChangeCounter += 1
        snapshot.status = .removed
        snapshot.removedAt = Date()
        await ConnectionStateChanges.shared.publish(
            state: .removed,
            for: snapshot,
            origin: .ios
        )
        // Hard-delete on the local side. This is the v5.3
        // contract: explicit disconnect is a real delete, not a
        // tombstone. The Mac side mirrors this via the CSC.
        ConnectionStore.shared.hardRemove(id: connection.id)
        ShareSyncEngineRegistry.shared.unregister(connectionId: connection.id)
        AutoPairDiscovery.shared.markRecentlyRemoved(macId: connection.macDeviceId)
        await LocalStore.shared.clearMacData(macId: connection.macDeviceId)
    }
}
