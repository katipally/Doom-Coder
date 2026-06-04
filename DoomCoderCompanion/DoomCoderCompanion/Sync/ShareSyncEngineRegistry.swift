// ShareSyncEngineRegistry.swift — DoomCoder Companion
// Owns one CKSyncEngine per accepted CKShare. Each share points at the
// same shared zone in CloudKit; the engines run independently so the iOS
// app can fetch from multiple Macs at once. The base CKSyncEngine
// (CompanionSyncEngine) handles the implicit iCloud (same-Apple-ID) path.
//
// v2.8 CRITICAL FIX: after accepting a CKShare, the participant's view
// of the share lives in `container.sharedCloudDatabase`, NOT in
// `privateCloudDatabase`. The previous implementation pointed the
// per-share engine at privateCloudDatabase, which meant the engine
// never saw any records even after the iOS user accepted the share.
// (The Mac's 3-second poll masked this bug: the Mac's "accepted!"
// detection fired before the iPhone had any records, so the UI looked
// right but the per-share engine was silently dead.)

import Foundation
import CloudKit
import Combine
import DoomCoderCore

@MainActor
final class ShareSyncEngineRegistry {

    static let shared = ShareSyncEngineRegistry()

    private var engines: [String: CKSyncEngine] = [:]
    private var subscriptions: [String: CKSyncEngine] = [:]
    private let container: CKContainer

    init(container: CKContainer = CKContainer(identifier: CloudKitConstants.containerIdentifier)) {
        self.container = container
    }

    /// Register (or refresh) a per-share CKSyncEngine for a Connection.
    /// Idempotent: calling twice with the same id is a no-op.
    func register(connection: Connection) {
        guard connection.status == .active,
              case let .ckShare(ref) = connection.route
        else { return }
        if engines[connection.id] != nil {
            // Already registered — nothing to do. The connection's
            // macId/iosDeviceId are reflected in CompanionSyncEngine
            // (which writes MacStatus/PeerStatus) and the per-share
            // engine doesn't need to know about them.
            return
        }
        // v2.8: shared database, not private. The accepted share
        // appears in the participant's shared database as a record
        // zone they have access to.
        let database = container.sharedCloudDatabase
        let stateKey = "doomcoder.sharesyncengine.\(connection.id).v2"
        let state: CKSyncEngine.State.Serialization? = {
            if let data = UserDefaults.standard.data(forKey: stateKey),
               let s = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data) {
                return s
            }
            return nil
        }()
        let delegate = ShareSubscription(
            connection: connection,
            shareURL: ref.shareURL,
            stateKey: stateKey
        )
        var config = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: state,
            delegate: delegate
        )
        config.automaticallySync = true
        let engine = CKSyncEngine(config)
        engines[connection.id] = engine
        subscriptions[connection.id] = engine
        // v2.8: explicit fetch to accelerate first sync after
        // acceptance. Without this, the engine waits for its
        // automaticallySync schedule (which is fine but slower on
        // first sync).
        Task.detached { [weak engine] in
            try? await engine?.fetchChanges()
        }
    }

    func unregister(connectionId: String) {
        engines.removeValue(forKey: connectionId)
        subscriptions.removeValue(forKey: connectionId)
    }

    func engine(for connectionId: String) -> CKSyncEngine? {
        engines[connectionId]
    }

    /// v2.8: self-heal existing paired devices. Wipes any per-share
    /// engines registered against the wrong database (private instead
    /// of shared) and re-registers them. Safe to call multiple times.
    /// Called from CompanionSyncEngine.start() once on app launch.
    func reconcileAll() {
        let activeIDs = Set(engines.keys)
        for conn in ConnectionStore.shared.connections {
            guard conn.status == .active,
                  case .ckShare = conn.route
            else { continue }
            // If we have a Connection but no engine for it, register.
            if !activeIDs.contains(conn.id) {
                register(connection: conn)
            }
        }
        // Note: we deliberately do NOT unregister engines whose
        // Connection has been removed — unregister happens explicitly
        // via IOSPairingCoordinator.remove. reconcileAll is a
        // forward-only fix-up.
    }
}

