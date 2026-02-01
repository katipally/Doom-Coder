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
        var agentResponse: Bool = true
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
