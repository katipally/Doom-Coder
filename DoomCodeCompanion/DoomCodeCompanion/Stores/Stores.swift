// Stores.swift — DoomCoder Companion
// Observable singleton stores that hold the decoded CloudKit state for the
// main app. Read-only iOS companion: MacStatusStore, AgentListStore, and
// NotificationLogStore.

import Foundation
import DoomCoderCore

// MARK: - MacStatusStore

/// Holds the latest MacStatusRecord for every paired Mac.
@MainActor
@Observable
final class MacStatusStore {

    static let shared = MacStatusStore()
    private init() {
        primaryMacIdOverride = AppGroupCache.defaults.string(forKey: Self.primaryMacIdKey)
        // Warm from App Group cache so the cold-launch UI shows the last
        // known Mac instantly, before the first CloudKit fetch resolves.
        if let cached = AppGroupCache.read([String: MacStatusRecord].self,
                                           forKey: Self.cacheKey) {
            byMacId = cached
        }
    }

    /// App Group cache key for the full byMacId snapshot.
    static let cacheKey = "cache.macStatus.byMacId"

    /// UserDefaults key (App Group) that pins a specific macId as the primary.
    /// When unset, primary falls back to "most recently seen Mac".
    static let primaryMacIdKey = "doomcoder.companion.primaryMacId"

    private(set) var byMacId: [String: MacStatusRecord] = [:]
    private(set) var primaryMacIdOverride: String?

    /// User-pinned primary Mac, if set and still visible. Otherwise the most
    /// recently seen Mac (preserves the v2.x behaviour for single-Mac users).
    var primary: MacStatusRecord? {
        if let id = primaryMacIdOverride, let pinned = byMacId[id] {
            return pinned
        }
        return byMacId.values.max(by: { $0.lastSeen < $1.lastSeen })
    }

    func setPrimary(_ macId: String?) {
        primaryMacIdOverride = macId
        if let id = macId {
            AppGroupCache.defaults.set(id, forKey: Self.primaryMacIdKey)
        } else {
            AppGroupCache.defaults.removeObject(forKey: Self.primaryMacIdKey)
        }
    }

    func upsert(_ r: MacStatusRecord) {
        byMacId[r.macId] = r
        AppGroupCache.write(byMacId, forKey: Self.cacheKey)
        LocalStore.shared.upsertMacStatus(r)
    }

    /// Removes a single Mac (multi-Mac disconnect), keeping the others. If it was
    /// the pinned primary, the pin clears and `primary` falls back to most-recent.
    func remove(macId: String) {
        byMacId[macId] = nil
        if primaryMacIdOverride == macId { setPrimary(nil) }
        AppGroupCache.write(byMacId, forKey: Self.cacheKey)
    }

    func clear() {
        byMacId.removeAll()
        primaryMacIdOverride = nil
        AppGroupCache.defaults.removeObject(forKey: Self.primaryMacIdKey)
        AppGroupCache.defaults.removeObject(forKey: Self.cacheKey)
    }
}

// MARK: - AgentListStore

/// Holds the configured agents from each Mac's AgentConfig record, scoped per
/// macId so multiple connected Macs don't overwrite each other. The plain
/// `agents`/`installedAgents`/`statuses` accessors reflect the ACTIVE Mac
/// (`MacStatusStore.primary`), so existing views show the selected Mac's agents
/// and re-render automatically when the user switches Macs.
@MainActor
@Observable
final class AgentListStore {

    static let shared = AgentListStore()
    private init() {}

    private var agentsByMac: [String: [TrackedAgent]] = [:]
    private var installedByMac: [String: Set<TrackedAgent>] = [:]
    private var statusesByMac: [String: [TrackedAgent: String]] = [:]
    /// macId → (agent rawValue → read-only "what you'll be notified about" rows),
    /// synced from the Mac. Drives the iOS capability card.
    private var deliverablesByMac: [String: [String: [AgentDeliverable]]] = [:]

    private var activeMacId: String? { MacStatusStore.shared.primary?.macId }

    // MARK: - Active-Mac accessors (used by the UI)

    var agents: [TrackedAgent] { activeMacId.flatMap { agentsByMac[$0] } ?? [] }
    var installedAgents: Set<TrackedAgent> { activeMacId.flatMap { installedByMac[$0] } ?? [] }
    var statuses: [TrackedAgent: String] { activeMacId.flatMap { statusesByMac[$0] } ?? [:] }

    // MARK: - Per-Mac accessors

    func agents(forMac macId: String) -> [TrackedAgent] { agentsByMac[macId] ?? [] }
    func installedAgents(forMac macId: String) -> Set<TrackedAgent> { installedByMac[macId] ?? [] }
    func statuses(forMac macId: String) -> [TrackedAgent: String] { statusesByMac[macId] ?? [:] }

    /// Read-only "what you'll be notified about" rows the user enabled on the
    /// Mac for `agent`. Empty when the owning Mac hasn't synced them yet (the
    /// caller falls back to the static capability catalog). `macId` defaults to
    /// the active Mac.
    func deliverables(forAgent agent: TrackedAgent, macId: String? = nil) -> [AgentDeliverable] {
        let mac = macId ?? activeMacId
        return mac.flatMap { deliverablesByMac[$0]?[agent.rawValue] } ?? []
    }

    func updateState(agents newAgents: [TrackedAgent],
                     installed: [TrackedAgent],
                     statuses newStatuses: [TrackedAgent: String],
                     deliverables newDeliverables: [String: [AgentDeliverable]] = [:],
                     macId: String) {
        agentsByMac[macId] = newAgents.sorted { $0.displayName < $1.displayName }
        installedByMac[macId] = Set(installed)
        statusesByMac[macId] = newStatuses
        deliverablesByMac[macId] = newDeliverables
        LocalStore.shared.upsertAgentConfig(macId: macId, agents: newAgents)
    }

    /// Removes a single Mac's agent state (per-Mac disconnect).
    func clear(macId: String) {
        agentsByMac[macId] = nil
        installedByMac[macId] = nil
        statusesByMac[macId] = nil
        deliverablesByMac[macId] = nil
    }

    func clear() {
        agentsByMac.removeAll()
        installedByMac.removeAll()
        statusesByMac.removeAll()
        deliverablesByMac.removeAll()
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
    
    /// Logs for an agent, optionally scoped to a single Mac (multi-Mac).
    func fetchLogs(forAgent agent: TrackedAgent, macId: String? = nil) async -> [NotificationLogRecord] {
        return await LocalStore.shared.fetchNotifications(forAgent: agent, macId: macId, limit: 100)
    }

    func clear() {
        entries.removeAll()
        AppGroupCache.defaults.removeObject(forKey: AppGroupCache.notificationLogKey)
    }

    func clear(forAgent agent: TrackedAgent, macId: String? = nil) {
        entries.removeAll { $0.agent == agent.rawValue && (macId == nil || $0.macId == macId) }
        AppGroupCache.write(entries, forKey: AppGroupCache.notificationLogKey)
        LocalStore.shared.clearNotifications(forAgent: agent, macId: macId)
    }

    func delete(_ record: NotificationLogRecord) {
        entries.removeAll { $0.notifId == record.notifId }
        AppGroupCache.write(entries, forKey: AppGroupCache.notificationLogKey)
        LocalStore.shared.deleteNotification(notifId: record.notifId)
    }
}
