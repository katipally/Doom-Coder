// PeerStatusPublisher.swift — DoomCoder Companion
//
// v2.7: writes a PeerStatusRecord into the shared DoomCoderZone on a
// 60-second heartbeat so the Mac can see this iOS device in its
// Connections tab. Symmetric to CloudKitPusher.publishMacStatus on the
// Mac side.
//
// Uses the same CKSyncEngine that CompanionSyncEngine already
// constructs — no second engine, no second zone, no second
// subscription. The engine's existing delegate already serializes
// saves; we just queue a `.saveRecord` on a timer.

import Foundation
import CloudKit
import UIKit
import Observation
import DoomCoderCore

@MainActor
final class PeerStatusPublisher {

    static let shared = PeerStatusPublisher()

    private let heartbeatInterval: TimeInterval = 60
    private var heartbeatTimer: Timer?
    private var lastPublishedAt: Date = .distantPast

    private init() {}

    /// Start the heartbeat. Idempotent. The first publish happens
    /// immediately so the Mac sees the peer within a few seconds of
    /// the iOS app launching, then once per minute.
    func start() {
        stop()
        publish()
        let timer = Timer(timeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// Force-publish right now (used on app foreground, after a
    /// connection change, etc.). Debounced to one publish per 10s so
    /// a flurry of events doesn't spam CloudKit.
    func publishNow(force: Bool = false) {
        if force || Date().timeIntervalSince(lastPublishedAt) > 10 {
            publish()
        }
    }

    private func publish() {
        let engine = CompanionSyncEngine.shared
        guard engine.zoneReady else {
            // Engine isn't ready yet (still in setup or no zone).
            // Retry on the next timer tick. Don't enqueue a save
            // against an un-initialised engine — the engine guards
            // re-entry and would log warnings.
            return
        }

        let macId: String? = MacStatusStore.shared.primary?.macId
        // v2.8: include the share URL when we have one so the Mac can
        // reconcile a placeholder ckShare Connection row (created on
        // accept with a random iosDeviceId) with our stable iosId.
        let activeConnection = ConnectionStore.shared.connections.first { $0.status == .active }
        let shareURLString = activeConnection?.ckShareRef?.shareURLString

        let rec = PeerStatusRecord(
            iosDeviceId: IosDeviceId.current,
            name: IosDeviceId.displayName,
            model: IosDeviceId.model,
            systemName: IosDeviceId.systemName,
            appVersion: IosDeviceId.appVersion,
            lastSeen: Date(),
            route: "iCloud",
            macId: macId,
            shareURLString: shareURLString
        )
        guard let engineRef = engine.internalSyncEngine else { return }
        engineRef.state.add(pendingRecordZoneChanges: [.saveRecord(rec.recordID)])
        PeerStatusPublisherCache.shared.put(rec)
        lastPublishedAt = Date()
        SyncTelemetry.shared.record(.stateUpdate, side: .ios, detail: "peerStatus heartbeat")
    }
}

// MARK: - Local cache of the last-built record (for the engine delegate)

/// Holds the most recently built PeerStatusRecord so the engine's
/// `nextRecordZoneChangeBatch` can materialise the CKRecord on demand
/// (matching the Mac-side pattern of building the record inside the
/// batch closure to preserve `recordChangeTag`).
@MainActor
final class PeerStatusPublisherCache {
    static let shared = PeerStatusPublisherCache()
    private init() {}

    private var pending: [String: PeerStatusRecord] = [:]
    private var serverCache: [String: CKRecord] = [:]

    func put(_ r: PeerStatusRecord) {
        pending[r.recordID.recordName] = r
    }

    /// Builds (or rebuilds) the CKRecord for a pending save. Returns
    /// `nil` if no record is queued under that id (e.g. the user
    /// toggled a connection since the heartbeat was queued).
    func buildCKRecord(for recordID: CKRecord.ID) -> CKRecord? {
        guard let rec = pending[recordID.recordName] else { return nil }
        // Preserve server-known changeTag if we've seen this record
        // before — same lesson as the Mac pusher.
        let base = serverCache[recordID.recordName]
        let built = rec.toCKRecord(base: base)
        // If we built from scratch, copy fields into the base so the
        // changeTag isn't lost.
        if let base = base {
            for key in built.allKeys() { base[key] = built[key] }
            return base
        }
        return built
    }

    /// Called by the engine delegate when a save completes so the
    /// in-memory cache stays consistent.
    func didSave(_ record: CKRecord) {
        serverCache[record.recordID.recordName] = record
        pending.removeValue(forKey: record.recordID.recordName)
    }
}

