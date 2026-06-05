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

    // MARK: - URL entry points

    /// Called by AppDelegate when doomcoder://pair?ckShareURL=... arrives.
    public func handle(pairURL: URL) async {
        guard let parsed = PairURLHandler.parse(url: pairURL) else {
            let err = ConnectionError.invalidPairingCode
            lastError = err
            phase = .failed(err)
            return
        }
        await accept(shareURL: parsed.shareURL, containerIdentifier: parsed.containerIdentifier)
    }

    /// Called by the QR scanner with the raw scanned string.
    public func handle(scannedString: String) async {
        // QR may contain either a doomcoder:// URL or a raw CKShare URL.
        if let url = URL(string: scannedString), url.scheme == "doomcoder" {
            await handle(pairURL: url)
        } else if let url = URL(string: scannedString), url.host == "www.icloud.com" {
            await accept(
                shareURL: url,
                containerIdentifier: CloudKitConstants.containerIdentifier
            )
        } else {
            let err = ConnectionError.invalidPairingCode
            lastError = err
            phase = .failed(err)
        }
    }

    // MARK: - Share acceptance

    private func accept(shareURL: URL, containerIdentifier: String) async {
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
                            isSameAccount: true
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
                isSameAccount: isOwner
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
        isSameAccount: Bool
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
            ConnectionStore.shared.upsert(refreshed)
            registerSyncEngine(for: refreshed, isSameAccount: isSameAccount)
            successMessage = "Paired with a Mac"
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
            ckShareRef: ref
        )
        ConnectionStore.shared.upsert(connection)
        registerSyncEngine(for: connection, isSameAccount: isSameAccount)
        successMessage = "Paired with a Mac"
        presentSuccess = true
        phase = .active(connection)
    }

    private func registerSyncEngine(for connection: Connection, isSameAccount: Bool) {
        if isSameAccount {
            Task { await CompanionSyncEngine.shared.fetchChanges() }
        } else {
            ShareSyncEngineRegistry.shared.register(connection: connection)
        }
        // Signal the Mac immediately so it detects acceptance within seconds.
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
            await accept(shareURL: shareURL, containerIdentifier: CloudKitConstants.containerIdentifier)
        } catch let err as ConnectionError {
            lastError = err
            phase = .failed(err)
        } catch {
            let err = ConnectionError.invalidPairingCode
            lastError = err
            phase = .failed(err)
        }
    }

    // MARK: - Removal

    public func remove(connection: Connection) async {
        // Signal the Mac before local teardown so it receives an APNs push
        // and removes the connection within seconds.
        await PeerStatusPublisher.shared.publishDisconnect(connection: connection)
        ConnectionStore.shared.remove(id: connection.id)
        ShareSyncEngineRegistry.shared.unregister(connectionId: connection.id)
        // Wipe per-Mac local caches so the iOS app no longer holds that
        // Mac's status / agents / notifications. The Mac keeps the share
        // record (user can revoke from iCloud settings).
        await LocalStore.shared.clearMacData(macId: connection.macDeviceId)
    }
}
