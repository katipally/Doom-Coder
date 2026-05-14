import Foundation

// Stores global + per-agent notification channel preferences in UserDefaults.
// Channels: macOS notifications, ntfy. Each can be toggled globally and overridden per-agent.
struct ChannelStore {
    static let defaultsKey = "doomcoder.channels.v2"
    static let prefsKey = "doomcoder.notification.prefs.v1"

    struct ChannelConfig: Codable, Sendable, Equatable {
        var macNotification: Bool = true
        var ntfy: Bool = false
    }

    /// Which event phases should trigger a push notification.
    struct NotificationPrefs: Codable, Sendable, Equatable {
        var sessionStart: Bool = false
        var sessionEnd: Bool = true
        var error: Bool = true
        var permissionNeeded: Bool = true
        var agentResponse: Bool = false
        var subagentStart: Bool = false
        var subagentEnd: Bool = false
        var toolUse: Bool = false

        func shouldNotify(phase: String) -> Bool {
            switch phase {
            case "sessionStart":      return sessionStart
            case "sessionEnd":        return sessionEnd
            case "error", "toolError": return error
            case "permissionNeeded":  return permissionNeeded
            case "agentResponse":     return agentResponse
            case "subagentStart":     return subagentStart
            case "subagentEnd":       return subagentEnd
            case "toolStart", "toolEnd": return toolUse
            default:                  return false
            }
        }
    }

    struct Store: Codable, Sendable {
        var global: ChannelConfig = ChannelConfig()
        var perAgent: [String: ChannelConfig] = [:]
    }

    static func load() -> Store {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(Store.self, from: data)
        else { return Store() }
        return decoded
    }

    static func save(_ store: Store) {
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Returns effective channels for an agent (per-agent override if set, else global).
    static func effectiveChannels(for agent: TrackedAgent) -> ChannelConfig {
        let store = load()
        return store.perAgent[agent.rawValue] ?? store.global
    }

    static func setGlobal(_ config: ChannelConfig) {
        var store = load()
        store.global = config
        save(store)
    }

    static func setPerAgent(_ agent: TrackedAgent, config: ChannelConfig?) {
        var store = load()
        if let config {
            store.perAgent[agent.rawValue] = config
        } else {
            store.perAgent.removeValue(forKey: agent.rawValue)
        }
        save(store)
    }

    static func hasOverride(for agent: TrackedAgent) -> Bool {
        load().perAgent[agent.rawValue] != nil
    }

    static func clearOverride(for agent: TrackedAgent) {
        setPerAgent(agent, config: nil)
    }

    // MARK: - Notification preferences
    //
    // v2.3.0 introduces a per-agent prefs map keyed by TrackedAgent.rawValue.
    // The global NotificationPrefs remains the fallback (and the curated
    // default for new installs). Per-agent overrides let users silence one
    // agent without disarming notifications globally.

    /// Bumped when the default allowlist changes. Current defaults: 4-phase
    /// — sessionStart, sessionEnd, error, permissionNeeded. agentResponse is
    /// intentionally OFF to prevent spam from Claude's Notification hooks.
    private static let prefsMigrationKey = "doomcoder.notification.prefs.migrated.v6"

    private static let perAgentPrefsKey = "doomcoder.notification.prefs.perAgent.v1"

    /// Run once at launch. If this build's migration flag hasn't been set,
    /// overwrite saved prefs with the curated defaults and record the flag.
    /// v6 also wipes any stale per-agent prefs that pointed at the old
    /// cross-agent NormalizedEventPhase taxonomy.
    static func migratePrefsIfNeeded() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: prefsMigrationKey) else { return }
        savePrefs(NotificationPrefs())
        ud.removeObject(forKey: perAgentPrefsKey)
        ud.set(true, forKey: prefsMigrationKey)
    }

    static func loadPrefs() -> NotificationPrefs {
        guard let data = UserDefaults.standard.data(forKey: prefsKey),
              let decoded = try? JSONDecoder().decode(NotificationPrefs.self, from: data)
        else { return NotificationPrefs() }
        return decoded
    }

    static func savePrefs(_ prefs: NotificationPrefs) {
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: prefsKey)
        }
    }

    // MARK: - Per-agent prefs

    static func loadPerAgentPrefs() -> [String: NotificationPrefs] {
        guard let data = UserDefaults.standard.data(forKey: perAgentPrefsKey),
              let decoded = try? JSONDecoder().decode([String: NotificationPrefs].self, from: data)
        else { return [:] }
        return decoded
    }

    static func savePerAgentPrefs(_ map: [String: NotificationPrefs]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: perAgentPrefsKey)
        }
    }

    /// Resolve effective prefs for an agent: per-agent override if present,
    /// else the global default.
    static func loadPrefs(for agent: TrackedAgent) -> NotificationPrefs {
        let map = loadPerAgentPrefs()
        if let p = map[agent.rawValue] { return p }
        return loadPrefs()
    }

    static func setPrefs(_ prefs: NotificationPrefs?, for agent: TrackedAgent) {
        var map = loadPerAgentPrefs()
        if let prefs {
            map[agent.rawValue] = prefs
        } else {
            map.removeValue(forKey: agent.rawValue)
        }
        savePerAgentPrefs(map)
    }

    static func hasPrefsOverride(for agent: TrackedAgent) -> Bool {
        loadPerAgentPrefs()[agent.rawValue] != nil
    }

    /// Ensures every known agent has an explicit NotificationPrefs entry using
    /// the global defaults. Called at launch so the per-agent UI always binds
    /// to real stored prefs instead of falling back to the global.
    static func initializeAllAgentPrefsIfNeeded() {
        var map = loadPerAgentPrefs()
        var changed = false
        for agent in TrackedAgent.allCases where map[agent.rawValue] == nil {
            map[agent.rawValue] = NotificationPrefs()
            changed = true
        }
        if changed { savePerAgentPrefs(map) }
    }
}
