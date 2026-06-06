// Stores.swift — DoomCoder Companion
// Observable singleton stores that hold the decoded CloudKit state for the
// main app. Read-only iOS companion: MacStatusStore, AgentListStore, and
// NotificationLogStore.

import Foundation
import DoomCoderCore

// MARK: - MacStatusStore

/// Holds the latest MacStatusRecord for every paired Mac. The "primary" is
/// always the most recently seen Mac — there is no user-selectable pinning
/// because the iOS app is read-only and never pairs explicitly.
@MainActor
@Observable
final class MacStatusStore {

    static let shared = MacStatusStore()
    private init() {
        // Warm from App Group cache so the cold-launch UI shows the last
        // known Mac instantly, before the first CloudKit fetch resolves.
        if let cached = AppGroupCache.read([String: MacStatusRecord].self,
                                           forKey: Self.cacheKey) {
            byMacId = cached
        }
    }

    /// App Group cache key for the full byMacId snapshot.
    static let cacheKey = "cache.macStatus.byMacId"

    private(set) var byMacId: [String: MacStatusRecord] = [:]

    /// Most recently seen Mac.
    var primary: MacStatusRecord? {
        byMacId.values.max(by: { $0.lastSeen < $1.lastSeen })
    }

    func upsert(_ r: MacStatusRecord) {
        byMacId[r.macId] = r
        AppGroupCache.write(byMacId, forKey: Self.cacheKey)
        LocalStore.shared.upsertMacStatus(r)
    }

    func clear() {
        byMacId.removeAll()
        AppGroupCache.defaults.removeObject(forKey: Self.cacheKey)
    }
}

// MARK: - AgentListStore

/// Holds the configured agents from the Mac's AgentConfig record.
@MainActor
@Observable
final class AgentListStore {

    static let shared = AgentListStore()
    private init() {
        // Warm installedAgents from cache so the filter works before first sync.
        if let slugs = AppGroupCache.read([String].self, forKey: AppGroupCache.installedAgentsKey) {
            installedAgents = Set(slugs.compactMap { TrackedAgent(rawValue: $0) })
        }
        Task {
            agents = await LocalStore.shared.fetchAgents()
        }
    }

    private(set) var agents: [TrackedAgent] = []
    /// Subset of `agents` that are installed on the Mac. Read by the UI to
    /// dim or badge non-installed rows.
    private(set) var installedAgents: Set<TrackedAgent> = []
    /// Per-agent human-readable status (e.g. "running", "waiting for approval",
    /// "closed"). Empty means status is unknown.
    private(set) var statuses: [TrackedAgent: String] = [:]
    /// v2.7+: per-Mac agent list. Lets the dashboard filter by MacId when
    /// the user has more than one Mac paired (the Mac switcher).
    private(set) var agentsByMacId: [String: [TrackedAgent]] = [:]

    func updateAgents(_ newAgents: [TrackedAgent], macId: String) {
        agents = newAgents.sorted { $0.displayName < $1.displayName }
        agentsByMacId[macId] = newAgents.sorted { $0.displayName < $1.displayName }
        LocalStore.shared.upsertAgentConfig(macId: macId, agents: newAgents)
    }

    func updateState(agents newAgents: [TrackedAgent],
                     installed: [TrackedAgent],
                     statuses newStatuses: [TrackedAgent: String],
                     macId: String) {
        agents = newAgents.sorted { $0.displayName < $1.displayName }
        agentsByMacId[macId] = newAgents.sorted { $0.displayName < $1.displayName }
        installedAgents = Set(installed)
        statuses = newStatuses
        LocalStore.shared.upsertAgentConfig(macId: macId, agents: newAgents)
        // Persist so the filter is correct on next cold launch before first sync.
        AppGroupCache.write(installed.map { $0.rawValue }, forKey: AppGroupCache.installedAgentsKey)
    }

    func clear() {
        agents.removeAll()
        installedAgents.removeAll()
        statuses.removeAll()
        agentsByMacId.removeAll()
    }
}

// MARK: - NotificationLogStore

/// Append-only log of NotificationLogRecords, mirrored to App Group so the NSE
/// can also read recent entries without a CloudKit round-trip.
@MainActor
@Observable
final class NotificationLogStore {

    static let shared = NotificationLogStore()
    private init() {
        // Warm from the App Group cache so entries survive a cold launch.
        if let cached = AppGroupCache.read([NotificationLogRecord].self,
                                           forKey: AppGroupCache.notificationLogKey) {
            entries = cached
        }
    }

    var entries: [NotificationLogRecord] = []

    private let maxEntries = 500

    func append(_ r: NotificationLogRecord) {
        // Deduplicate by notifId.
        guard !entries.contains(where: { $0.notifId == r.notifId }) else { return }
        entries.insert(r, at: 0)                    // maintain ts-desc order
        entries.sort { $0.ts > $1.ts }
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        // Persist the trimmed list for the NSE.
        AppGroupCache.write(entries, forKey: AppGroupCache.notificationLogKey)
        LocalStore.shared.upsertNotificationLog(r)
    }

    func fetchLogs(forAgent agent: TrackedAgent, macId: String? = nil) async -> [NotificationLogRecord] {
        return await LocalStore.shared.fetchNotifications(forAgent: agent, macId: macId, limit: 100)
    }

    func clear() {
        entries.removeAll()
        AppGroupCache.defaults.removeObject(forKey: AppGroupCache.notificationLogKey)
    }

    func clear(forAgent agent: TrackedAgent) {
        entries.removeAll { $0.agent == agent.rawValue }
        AppGroupCache.write(entries, forKey: AppGroupCache.notificationLogKey)
        LocalStore.shared.clearNotifications(forAgent: agent)
    }

    func delete(_ record: NotificationLogRecord) {
        entries.removeAll { $0.notifId == record.notifId }
        AppGroupCache.write(entries, forKey: AppGroupCache.notificationLogKey)
        LocalStore.shared.deleteNotification(notifId: record.notifId)
    }
}
