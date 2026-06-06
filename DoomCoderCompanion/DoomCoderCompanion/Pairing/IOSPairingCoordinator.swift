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

    // MARK: - Inbound same-iCloud pairing request (v6: Mac initiates)

    /// v6: the Mac sent a CSC{requested} to this iPhone (same-iCloud picker).
    /// Create/refresh a `.pendingOnPhone` row so the Accept/Decline prompt
    /// surfaces. The user explicitly accepts before any connection goes active.
    public func ingestInboundRequest(macId: String, macName: String) {
        let iosId = IosDeviceId.current
        let id = Connection.implicitConnectionId(macId: macId, iosDeviceId: iosId)
        if let existing = ConnectionStore.shared.connections.first(where: { $0.id == id }) {
            if existing.status == .active { return }   // already paired
            var updated = existing
            updated.status = .pendingOnPhone
            ConnectionStore.shared.upsert(updated)
        } else {
            let connection = Connection(
                id: id,
                macDeviceId: macId,
                iosDeviceId: iosId,
                route: .iCloud,
                status: .pendingOnPhone,
                createdAt: Date(),
                lastSyncAt: nil,
                ckShareRef: nil,
                pairingOrigin: .sameICloud,
                stateChangeCounter: 1
            )
            ConnectionStore.shared.upsert(connection)
        }
        NotificationCenter.default.post(
            name: .incomingPairRequest, object: nil,
            userInfo: ["macId": macId, "macName": macName]
        )
    }

    /// User tapped Accept on the same-iCloud request. Mark active and tell the
    /// Mac via CSC{accepted, origin:ios}.
    public func acceptInboundRequest(macId: String) async {
        let iosId = IosDeviceId.current
        let id = Connection.implicitConnectionId(macId: macId, iosDeviceId: iosId)
        guard var conn = ConnectionStore.shared.connections.first(where: { $0.id == id }) else { return }
        conn.status = .active
        conn.lastSyncAt = Date()
        conn.stateChangeCounter += 1
        ConnectionStore.shared.upsert(conn)
        await ConnectionStateChanges.shared.publish(state: .accepted, for: conn, origin: .ios)
        ConnectionNotifier.shared.notifyConnected(macName: MacStatusStore.shared.byMacId[macId]?.name)
    }

    /// v7: promptless same-iCloud connect. The Mac tapped this iPhone in its
    /// picker (CSC{accepted, origin:mac}); connect directly and echo back
    /// CSC{accepted, origin:ios} so both sides agree. `counter` is the Mac's
    /// CSC counter — we send back a strictly-greater one.
    public func connectFromMacInitiated(macId: String, counter: Int) {
        let iosId = IosDeviceId.current
        let id = Connection.implicitConnectionId(macId: macId, iosDeviceId: iosId)
        var conn: Connection
        if let existing = ConnectionStore.shared.connections.first(where: { $0.id == id }) {
            conn = existing
            conn.status = .active
            conn.lastSyncAt = Date()
            conn.stateChangeCounter = max(conn.stateChangeCounter, counter) + 1
            if conn.removedAt != nil { conn.removedAt = nil }
        } else {
            conn = Connection(
                id: id,
                macDeviceId: macId,
                iosDeviceId: iosId,
                route: .iCloud,
                status: .active,
                createdAt: Date(),
                lastSyncAt: Date(),
                ckShareRef: nil,
                pairingOrigin: .sameICloud,
                stateChangeCounter: counter + 1,
                shareAcceptedAt: Date()
            )
        }
        ConnectionStore.shared.upsert(conn)
        let macName = MacStatusStore.shared.byMacId[macId]?.name
        ConnectionNotifier.shared.notifyConnected(macName: macName)
        // Echo back so the Mac confirms the iPhone joined, and pull data now.
        Task {
            await ConnectionStateChanges.shared.publish(state: .accepted, for: conn, origin: .ios)
            await CompanionSyncEngine.shared.fetchChanges()
            PeerStatusPublisher.shared.publishNow(force: true)
        }
    }

    /// User tapped Decline. Drop the pending row and tell the Mac.
    public func declineInboundRequest(macId: String) async {
        let iosId = IosDeviceId.current
        let id = Connection.implicitConnectionId(macId: macId, iosDeviceId: iosId)
        guard let conn = ConnectionStore.shared.connections.first(where: { $0.id == id }) else { return }
        await ConnectionStateChanges.shared.publish(state: .denied, for: conn, origin: .ios)
        ConnectionStore.shared.remove(id: id)
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
        // AirDrop, Mail) — mark the origin as `.link`.
        switch parsed {
        case let .ckShare(shareURL, container):
            await accept(shareURL: shareURL, containerIdentifier: container, origin: .link)
        case let .sameICloud(macId, macUser):
            await acceptSameICloud(macId: macId, macUserRecordID: macUser, origin: .link)
        }
    }

    /// Called by the QR scanner with the raw scanned string.
    public func handle(scannedString: String) async {
        // QR may contain either a doomcoder:// URL or a raw CKShare URL.
        if let url = URL(string: scannedString), url.scheme == "doomcoder" {
            // The Mac QR encodes a doomcoder:// URL — either a CKShare
            // (different iCloud) or a same-iCloud payload. Mark origin `.qr`.
            guard let parsed = PairURLHandler.parse(url: url) else {
                let err = ConnectionError.invalidPairingCode
                lastError = err
                phase = .failed(err)
                return
            }
            switch parsed {
            case let .ckShare(shareURL, container):
                await accept(shareURL: shareURL, containerIdentifier: container, origin: .qr)
            case let .sameICloud(macId, macUser):
                await acceptSameICloud(macId: macId, macUserRecordID: macUser, origin: .qr)
            }
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

            // Scenario A — Same iCloud account.
            //   Canonical check: compare the share OWNER's userRecordID against
            //   THIS device's own userRecordID. If they match, the iPhone is on
            //   the same Apple ID as the Mac — it already owns the private zone,
            //   so CloudKit rejects .accept() ("owner participant tried to accept
            //   share") and we should sync via the private DB, not the shared DB.
            //   This replaces the racy `participantRole == .owner`, which can
            //   momentarily report a non-owner role before the share propagates
            //   and was the cause of "same Apple ID labelled Different iCloud".
            //   We fall back to participantRole only if the userRecordID fetch
            //   fails (e.g. transient iCloud error).
            let myRecordName = await IosDeviceId.iCloudUserRecordName()
            let isOwner: Bool = {
                if let mine = myRecordName, !mine.isEmpty, !ownerRecordName.isEmpty {
                    return mine == ownerRecordName
                }
                return metadata.participantRole == .owner
            }()

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

            // Capture the Mac owner's iCloud identity (name/email) for a
            // different-Apple-ID pairing so the iPhone's Mac card can show who
            // it's connected to. Same-account shows "Same iCloud" instead.
            let ownerIdentity = isOwner ? (name: nil, email: nil)
                                        : Self.identityDisplay(metadata.ownerIdentity)
            try await persistConnection(
                shareURL: shareURL,
                containerIdentifier: containerIdentifier,
                ownerRecordName: ownerRecordName,
                isSameAccount: isOwner,
                origin: origin,
                peerName: ownerIdentity.name,
                peerEmail: ownerIdentity.email
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

    /// Extracts a display name + email from a CKShare participant identity
    /// (non-deprecated; populated only if the user shared their identity).
    static func identityDisplay(_ identity: CKUserIdentity?) -> (name: String?, email: String?) {
        guard let identity else { return (nil, nil) }
        let name: String? = identity.nameComponents.map {
            PersonNameComponentsFormatter().string(from: $0)
        }.flatMap { $0.isEmpty ? nil : $0 }
        let email = identity.lookupInfo?.emailAddress
        return (name, (email?.isEmpty == false) ? email : nil)
    }

    private func persistConnection(
        shareURL: URL,
        containerIdentifier: String,
        ownerRecordName: String,
        isSameAccount: Bool,
        origin: PairingOrigin,
        peerName: String? = nil,
        peerEmail: String? = nil
    ) async throws {
        // Same-account connections use the sentinel so PeerStatusPublisher knows
        // to use the private-DB path instead of the shared-DB path.
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
            if let peerName { refreshed.peerAccountName = peerName }
            if let peerEmail { refreshed.peerAccountEmail = peerEmail }
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
            shareAcceptedAt: Date(),
            peerAccountName: peerName,
            peerAccountEmail: peerEmail
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
            // v6: a single shared-DB engine handles ALL accepted shares.
            // Just kick a fetch so the newly-accepted share's zone is pulled
            // promptly (it auto-discovers the zone via the DB subscription).
            Task { await SharedDatabaseSync.shared.fetchChanges() }
        }
        // Belt-and-braces: a PeerStatus heart-beat lands on the next event,
        // so the Mac always has at least one signal path to discover the
        // iOS device.
        PeerStatusPublisher.shared.publishNow(force: true)
        ConnectionNotifier.shared.notifyConnected(
            macName: MacStatusStore.shared.byMacId[connection.macDeviceId]?.name
        )
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
            // Same-iCloud code: no CKShare — resolve to the Mac's identity and
            // run the CSC handshake instead.
            if (record["kind"] as? String) == "sameICloud" {
                guard let macId = record["macId"] as? String, !macId.isEmpty,
                      let macUser = record["macUserRecordID"] as? String, !macUser.isEmpty else {
                    throw ConnectionError.invalidPairingCode
                }
                await acceptSameICloud(macId: macId, macUserRecordID: macUser, origin: .code)
                return
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

    // MARK: - Same-iCloud code / QR / link acceptance

    /// Connect to a same-iCloud Mac discovered via its code / QR / link. No
    /// CKShare is involved — we verify the Mac is on THIS Apple ID, create an
    /// active connection locally, and send CSC{accepted, origin:ios}. The Mac's
    /// ConnectionStateChanges.ingest creates its matching row on receipt.
    public func acceptSameICloud(macId: String, macUserRecordID: String, origin: PairingOrigin) async {
        guard !macId.isEmpty else {
            let err = ConnectionError.invalidPairingCode
            lastError = err; phase = .failed(err); return
        }
        // Same-account guard: the code/QR must belong to an iPhone on the same
        // Apple ID. If the record names differ, this is actually a different
        // iCloud — reject (the user should use the CKShare QR instead).
        let myUser = await IosDeviceId.iCloudUserRecordName()
        guard let myUser, myUser == macUserRecordID else {
            let err = ConnectionError.invalidPairingCode
            lastError = err; phase = .failed(err); return
        }

        let iosId = IosDeviceId.current
        let id = Connection.implicitConnectionId(macId: macId, iosDeviceId: iosId)
        var conn: Connection
        if let existing = ConnectionStore.shared.connections.first(where: { $0.id == id }) {
            conn = existing
            conn.status = .active
            conn.lastSyncAt = Date()
            conn.stateChangeCounter += 1
            if conn.removedAt != nil { conn.removedAt = nil }
        } else {
            conn = Connection(
                id: id,
                macDeviceId: macId,
                iosDeviceId: iosId,
                route: .iCloud,
                status: .active,
                createdAt: Date(),
                lastSyncAt: Date(),
                ckShareRef: nil,
                pairingOrigin: .sameICloud,
                stateChangeCounter: 1,
                shareAcceptedAt: Date()
            )
        }
        ConnectionStore.shared.upsert(conn)
        // Tell the Mac within 1-3s; its ingest creates/activates the row.
        await ConnectionStateChanges.shared.publish(state: .accepted, for: conn, origin: .ios)
        Task { await CompanionSyncEngine.shared.fetchChanges() }
        PeerStatusPublisher.shared.publishNow(force: true)
        let macName = MacStatusStore.shared.byMacId[macId]?.name
        successMessage = macName.map { "Paired with \($0)" } ?? "Paired with this Mac"
        presentSuccess = true
        ConnectionNotifier.shared.notifyConnected(macName: macName)
        phase = .active(conn)
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
    ///      nothing would re-add the row (no auto-attach), but it
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
        // v7: no suppression — the Mac stays discoverable for an explicit re-pair.
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
        await LocalStore.shared.clearMacData(macId: connection.macDeviceId)
        ConnectionNotifier.shared.notifyDisconnected(
            macName: MacStatusStore.shared.byMacId[connection.macDeviceId]?.name
        )
    }
}
