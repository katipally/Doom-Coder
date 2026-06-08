// CloudKitPusherLifecycle.swift
//
// Glue layer between Mac runtime events and the CloudKitPusher singleton.
// Responsibilities:
//   • Publish AgentConfig once the pusher is ready, and again whenever the
//     user toggles agents in the Tracking pane.
//   • Heartbeat MacStatus every 60s + on sleep/wake.
//   • Upload AgentIcon CKAssets once per launch (gated by per-agent SHA256).
//   • Hourly reaper that deletes NotificationLog records older than 7 days.

import Foundation
import CloudKit
import AppKit
import CryptoKit
import OSLog
import DoomCoderCore

@MainActor
final class CloudKitPusherLifecycle {

    static let shared = CloudKitPusherLifecycle()

    private let logger = Logger(subsystem: "com.doomcoder", category: "ckpusher.lifecycle")
    private var heartbeatTimer: Timer?
    private var reaperTimer: Timer?
    private var didPublishConfig = false
    private var didUploadIcons = false

    // Leading+trailing throttle for change-driven status publishing.
    private var _lastChangePublishAt: Date = .distantPast
    private var _pendingChangePublish: Task<Void, Never>?
    /// Minimum spacing between change-driven publishes. Coalesces bursts of hook
    /// events while keeping the first change in any burst near-instant.
    private let changePublishMinInterval: TimeInterval = 2.0

    private init() {}

    func start() {
        let nc = NotificationCenter.default

        // When pusher is ready → push initial AgentConfig + MacStatus + icons.
        nc.addObserver(forName: .cloudKitPusherReady, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.publishAll()
            }
        }

        // Tracking pane toggled an agent → republish AgentConfig.
        nc.addObserver(forName: .trackingStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.publishAgentConfig() }
        }

        // Agent installed or uninstalled → republish AgentConfig immediately.
        nc.addObserver(forName: .agentInstalledStateChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.publishAgentConfig() }
        }

        // CHANGE-DRIVEN publishing (push, not poll). Any agent session state
        // change (`.doomcoderNewEvent` — hook ingest, sweep, PID-exit finalize)
        // or app open/close (`.doomcoderProcessStateChanged`) republishes the
        // per-agent status + MacStatus so iOS mirrors the Mac within ~1s instead
        // of waiting up to a full 60s heartbeat. Routed through a leading+trailing
        // throttle so bursty hook traffic can't spam CloudKit writes.
        nc.addObserver(forName: .doomcoderNewEvent, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestStatusPublish() }
        }
        nc.addObserver(forName: .doomcoderProcessStateChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestStatusPublish() }
        }

        // Keep-awake state changed (local toggle, hotkey, Auto transition, or a
        // remote command) → publish a fresh MacStatus so iOS mirrors it.
        nc.addObserver(forName: .sleepManagerStateChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.publishMacStatus() }
        }

        // Heartbeat — scheduled in `.common` modes so Mac→iOS status keeps
        // flowing even while the menu-bar panel is open (a `.default`-mode timer
        // would pause during event tracking and stale-out the iOS mirror).
        let hb = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.publishMacStatus()
                // Refresh AgentConfig too so per-agent statuses on iOS stay current.
                self?.publishAgentConfig()
            }
        }
        RunLoop.main.add(hb, forMode: .common)
        heartbeatTimer = hb

        // Hourly reaper
        let reaper = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { await self?.reapOldNotificationLogs() }
        }
        RunLoop.main.add(reaper, forMode: .common)
        reaperTimer = reaper
        // Also run reaper once 5 min after launch (so a fresh app catches up
        // without waiting an hour).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(300))
            await self.reapOldNotificationLogs()
        }
    }

    // MARK: - Publishing

    /// Coalesced, change-driven status publish. Publishes immediately on the
    /// leading edge of a burst (snappy), then at most once per
    /// `changePublishMinInterval`, always emitting the final state on the
    /// trailing edge so iOS converges on the latest status.
    private func requestStatusPublish() {
        guard CloudKitPusher.shared.isReady else { return }
        let now = Date()
        let sinceLast = now.timeIntervalSince(_lastChangePublishAt)
        if sinceLast >= changePublishMinInterval {
            _pendingChangePublish?.cancel()
            _pendingChangePublish = nil
            performStatusPublish()
        } else if _pendingChangePublish == nil {
            let wait = changePublishMinInterval - sinceLast
            _pendingChangePublish = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self._pendingChangePublish = nil
                self.performStatusPublish()
            }
        }
        // else: a trailing publish is already scheduled and will capture the
        // newest state when it fires.
    }

    private func performStatusPublish() {
        _lastChangePublishAt = Date()
        publishAgentConfig()
        publishMacStatus()
        // Flush the queued zone changes now so iOS sees them in ~1s instead of
        // waiting for CKSyncEngine's automatic-sync cadence or the safety timer.
        CloudKitPusher.shared.kickEngine()
    }

    private func publishAll() {
        publishAgentConfig()
        publishMacStatus()
        if !didUploadIcons {
            didUploadIcons = true
            uploadAgentIconsIfNeeded()
        }
    }

    private func publishAgentConfig() {
        guard CloudKitPusher.shared.isReady else { return }
        let enabledAgents = TrackedAgent.allCases.filter { TrackingStore.isEnabled($0) }
        let installedAgents = TrackedAgent.allCases.filter { AgentInstallerV2.isInstalled($0) }
        let manager = AgentTrackingManager.shared
        var statuses: [TrackedAgent: String] = [:]
        for agent in TrackedAgent.allCases {
            statuses[agent] = manager.effectiveState(for: agent).humanReadable
        }
        CloudKitPusher.shared.publishAgentConfig(
            agents: enabledAgents,
            installed: installedAgents,
            statuses: statuses
        )
        didPublishConfig = true
    }

    private func publishMacStatus() {
        guard CloudKitPusher.shared.isReady else { return }
        CloudKitPusher.shared.publishMacStatus()
    }

    // MARK: - Icons

    /// Hash the cached PNG for each TrackedAgent and upload a fresh AgentIcon
    /// CKAsset record when the SHA256 differs from what we've previously
    /// uploaded. The "previously uploaded" SHA is stored per-agent in
    /// UserDefaults so a content change picks up automatically.
    private func uploadAgentIconsIfNeeded() {
        let ud = UserDefaults.standard
        for agent in TrackedAgent.allCases {
            guard let url = AgentIconProvider.iconFileURL(for: agent),
                  let data = try? Data(contentsOf: url) else { continue }
            let sha = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            let key = "doomcoder.ckpusher.iconSHA.\(agent.rawValue)"
            if ud.string(forKey: key) == sha { continue }
            CloudKitPusher.shared.publishAgentIcon(agent: agent, pngFileURL: url, pngSHA256: sha)
            ud.set(sha, forKey: key)
        }
    }

    // MARK: - Reaper

    /// Delete NotificationLog records older than 7 days. CloudKit query is
    /// cheap on the private DB; we cap the batch at 200 per run.
    private func reapOldNotificationLogs() async {
        guard CloudKitPusher.shared.isReady else { return }
        let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
        let db = container.privateCloudDatabase
        // The Mac owns its per-Mac zone in its private DB, so the reaper queries
        // there (records are shared zone-wide but still live in the owner's DB).
        let zoneID = CloudKitPusher.shared.zoneID
        let cutoff = Date().addingTimeInterval(-7 * 86_400) as NSDate
        let pred = NSPredicate(format: "ts < %@", cutoff)
        let query = CKQuery(recordType: NotificationLogRecord.recordType, predicate: pred)
        do {
            let (results, _) = try await db.records(matching: query,
                                                    inZoneWith: zoneID,
                                                    desiredKeys: [],
                                                    resultsLimit: 200)
            let ids = results.compactMap { (id, _) in id }
            if ids.isEmpty { return }
            CloudKitPusher.shared.deleteNotificationLogs(recordIDs: ids)
            logger.notice("ckpusher.reaper: queued delete of \(ids.count, privacy: .public) old NotificationLog records")
        } catch {
            logger.error("ckpusher.reaper: query failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Notification.Name {
    /// Posted by TrackingStore.setEnabled so listeners can react to user
    /// toggles in the Tracking pane.
    static let trackingStoreChanged = Notification.Name("doomcoder.trackingStore.changed")

    /// Posted by AgentInstallerV2 after a successful install or uninstall.
    /// userInfo: ["agent": String, "installed": Bool].
    static let agentInstalledStateChanged = Notification.Name("doomcoder.agentInstalledState.changed")
}
