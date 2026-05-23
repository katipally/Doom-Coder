// SettingsSyncStatus.swift — Companion
// Observable singleton derived from SyncTelemetry for the Settings record.
// Drives the per-toggle PendingBadge and the navbar pending indicator.
// Lifecycle (per local edit):
//   localEdit -> pending=true, since=now
//   applied   -> pending=false, errorText=nil
//   nacked    -> pending=false, errorText="<CKError code>: …"
//   timeout (30s) -> pending=false, errorText="Timed out"
// auto-revertOnError is the caller's responsibility (UI re-reads
// SettingsStore.current after timeout / nack and updates its toggle).

import Foundation
import Observation
import DoomCoderCore
import CloudKit

@Observable
@MainActor
final class SettingsSyncStatus {
    static let shared = SettingsSyncStatus()

    private(set) var pending: Bool = false
    private(set) var pendingSince: Date? = nil
    private(set) var lastErrorText: String? = nil
    private(set) var lastAppliedAt: Date? = nil
    private(set) var lastLatencyMs: Int? = nil

    private var timeoutTask: Task<Void, Never>?
    private let timeoutSeconds: Int = 30
    /// Threshold above which the badge becomes visible.
    let visibilityThresholdMs: Int = 2_000

    private init() {
        NotificationCenter.default.addObserver(
            forName: SyncTelemetry.eventRecordedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let ev = note.object as? SyncEvent else { return }
            self.consume(ev)
        }
    }

    private func consume(_ ev: SyncEvent) {
        guard ev.recordType == CloudKitConstants.RecordType.settings else { return }
        switch ev.kind {
        case .localEdit, .enqueued:
            if ev.side == .ios {
                pending = true
                pendingSince = Date()
                lastErrorText = nil
                scheduleTimeout()
            }
        case .sent:
            // iOS-side: the server has accepted our write. The Mac will
            // apply it on its next push/fetch — that's its problem, not
            // ours. Treat `.sent` as our successful round-trip endpoint.
            if ev.side == .ios {
                let latency = pendingSince.map { Int(Date().timeIntervalSince($0) * 1000) }
                clearPending(success: true, latencyMs: latency)
            }
        case .applied:
            // Mac echoing a change we made — also clears pending if any.
            clearPending(success: true, latencyMs: ev.latencyMs)
        case .nacked, .engineError:
            clearPending(success: false, errorText: ev.detail ?? "Sync error")
        default:
            break
        }
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        let deadline = timeoutSeconds
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(deadline))
            await MainActor.run {
                guard let self, self.pending else { return }
                self.clearPending(success: false, errorText: "Timed out after \(deadline)s")
            }
        }
    }

    private func clearPending(success: Bool, latencyMs: Int? = nil, errorText: String? = nil) {
        pending = false
        pendingSince = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if success {
            lastAppliedAt = Date()
            lastLatencyMs = latencyMs
            lastErrorText = nil
        } else {
            lastErrorText = errorText
        }
    }
}
