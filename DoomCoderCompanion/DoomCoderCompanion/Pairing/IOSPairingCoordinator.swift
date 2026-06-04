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
        phase = .awaitingSystemAcceptance(
            shareURL: shareURL,
            containerIdentifier: containerIdentifier
        )
        do {
            let metadata: CKShare.Metadata
            do {
                metadata = try await container.shareMetadata(for: shareURL)
            } catch {
                throw ConnectionError.shareAcceptanceFailed(
                    "Couldn't look up that iCloud share. Make sure the Mac hasn't revoked it and that the QR is current."
                )
            }
            phase = .accepting(shareURL: shareURL, containerIdentifier: containerIdentifier)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                container.accept(metadata) { _, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
            try await persistConnection(
                shareURL: shareURL,
                containerIdentifier: containerIdentifier
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

    private func persistConnection(shareURL: URL, containerIdentifier: String) async throws {
        let ref = CKShareRef(
            shareURL: shareURL,
            ownerRecordName: "DoomCoderShare",
            containerIdentifier: containerIdentifier
        )
        // v2.8: deterministic id keyed on shareURLString. Re-scanning
        // the same QR reuses the existing row instead of creating a
        // new one — the upsert collapses.
        let id = Connection.deterministicId(for: .ckShare(ref))
        // Prefer the real Mac's stable id from MacStatusStore if
        // available; falls back to a placeholder that the Mac will
        // reconcile via the first PeerStatus heartbeat.
        let macId = MacStatusStore.shared.primary?.macId ?? DeviceIDFactory.make()
        // Pre-check at construction time: if the row already exists,
        // refresh its status / lastSyncAt in place rather than going
        // through the full ShareSyncEngineRegistry.register (which
        // is itself idempotent but does extra work).
        if let existing = ConnectionStore.shared.connections.first(where: { $0.id == id }) {
            var refreshed = existing
            refreshed.status = .active
            refreshed.lastSyncAt = Date()
            // Reconcile the macId if we just learned it.
            if macId != DeviceIDFactory.make() {
                refreshed.macDeviceId = macId
            }
            ConnectionStore.shared.upsert(refreshed)
            ShareSyncEngineRegistry.shared.register(connection: refreshed)
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
        ShareSyncEngineRegistry.shared.register(connection: connection)
        successMessage = "Paired with a Mac"
        presentSuccess = true
        phase = .active(connection)
    }

    // MARK: - Removal

    public func remove(connection: Connection) async {
        ConnectionStore.shared.remove(id: connection.id)
        ShareSyncEngineRegistry.shared.unregister(connectionId: connection.id)
        // Wipe per-Mac local caches so the iOS app no longer holds that
        // Mac's status / agents / notifications. The Mac keeps the share
        // record (user can revoke from iCloud settings).
        await LocalStore.shared.clearMacData(macId: connection.macDeviceId)
    }
}
