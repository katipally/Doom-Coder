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

        // Keep-awake state changed (local toggle, hotkey, Auto transition, or a
        // remote command) → publish a fresh MacStatus so iOS mirrors it.
        nc.addObserver(forName: .sleepManagerStateChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.publishMacStatus() }
        }

        // Heartbeat
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.publishMacStatus()
                // Refresh AgentConfig too so per-agent statuses on iOS stay current.
                self?.publishAgentConfig()
            }
        }

        // Hourly reaper
        reaperTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { await self?.reapOldNotificationLogs() }
        }
        // Also run reaper once 5 min after launch (so a fresh app catches up
        // without waiting an hour).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(300))
            await self.reapOldNotificationLogs()
        }
    }

    // MARK: - Publishing

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
            let state: AgentSessionState
            if let live = manager.liveSessions.first(where: { $0.agent == agent }) {
                state = live.displayState
            } else if manager.processMonitor.isAppRunning[agent] == true {
                state = agent.isIDEAgent ? .open : .running
            } else {
                state = .notRunning
            }
            statuses[agent] = state.humanReadable
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
        let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName,
                                     ownerName: CKCurrentUserDefaultName)
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
