import Foundation

// Stores global + per-agent notification channel preferences in UserDefaults.
// Channels: macOS local notifications, iOS companion push. Each can be
// toggled globally and overridden per-agent.
struct ChannelStore {
    static let defaultsKey = "doomcoder.channels.v3"
    static let legacyDefaultsKey = "doomcoder.channels.v2"
    static let prefsKey = "doomcoder.notification.prefs.v1"

    struct ChannelConfig: Codable, Sendable, Equatable {
        var macNotification: Bool = true
        var iOSCompanion: Bool = true
    }

    /// One-shot migration: drop the ntfy field from any previously-persisted
    /// v2 store, set iOSCompanion = true (the new default), persist under v3.
    static func migrateRemoveNtfyIfNeeded() {
        let ud = UserDefaults.standard
        guard ud.data(forKey: defaultsKey) == nil,
              let legacy = ud.data(forKey: legacyDefaultsKey) else { return }
        struct LegacyConfig: Codable { var macNotification: Bool = true; var ntfy: Bool = false }
        struct LegacyStore: Codable {
            var global: LegacyConfig = LegacyConfig()
            var perAgent: [String: LegacyConfig] = [:]
        }
        guard let decoded = try? JSONDecoder().decode(LegacyStore.self, from: legacy) else {
            ud.removeObject(forKey: legacyDefaultsKey)
            return
        }
        var fresh = Store()
        fresh.global = ChannelConfig(macNotification: decoded.global.macNotification, iOSCompanion: true)
        fresh.perAgent = decoded.perAgent.mapValues { ChannelConfig(macNotification: $0.macNotification, iOSCompanion: true) }
        save(fresh)
        ud.removeObject(forKey: legacyDefaultsKey)
        // Wipe out the old ntfy topic/server keys too.
        for k in ["doomcoder.ntfy.topic", "doomcoder.ntfy.server"] { ud.removeObject(forKey: k) }
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
            // "Sub-agent activity" toggle controls both start and end phases.
            case "subagentStart", "subagentEnd": return subagentStart
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

    /// Bumped when the default allowlist changes. Setting this flag to a new
    /// value on launch overwrites older saved prefs so users pick up the new
    /// curated defaults. Current defaults: 4-phase — sessionStart, sessionEnd,
    /// error, permissionNeeded. agentResponse is intentionally OFF to prevent
    /// notification spam from Claude's frequent Notification hook events.
    private static let prefsMigrationKey = "doomcoder.notification.prefs.migrated.v5"

    /// Run once at launch. If this build's migration flag hasn't been set,
    /// overwrite saved prefs with the curated defaults and record the flag.
    static func migratePrefsIfNeeded() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: prefsMigrationKey) else { return }
        savePrefs(NotificationPrefs())
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
}
