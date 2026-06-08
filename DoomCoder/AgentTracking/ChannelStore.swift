import Foundation

// Stores global + per-agent notification channel preferences in UserDefaults.
// Channels: macOS notifications, ntfy. Each can be toggled globally and overridden per-agent.
struct ChannelStore {
    static let defaultsKey = "doomcoder.channels.v2"

    struct ChannelConfig: Codable, Sendable, Equatable {
        var macNotification: Bool = true
        /// Send notifications to the iOS companion app via CloudKit.
        /// Legacy on-disk JSON used the key `ntfy`; we transparently read it
        /// into `cloudkit` so users upgrading from v2.3 don't lose their
        /// channel preference.
        var cloudkit: Bool = false

        enum CodingKeys: String, CodingKey {
            case macNotification
            case cloudkit
            case ntfy
        }

        init(macNotification: Bool = true, cloudkit: Bool = false) {
            self.macNotification = macNotification
            self.cloudkit = cloudkit
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.macNotification = (try? c.decode(Bool.self, forKey: .macNotification)) ?? true
            if let ck = try? c.decode(Bool.self, forKey: .cloudkit) {
                self.cloudkit = ck
            } else if let n = try? c.decode(Bool.self, forKey: .ntfy) {
                self.cloudkit = n
            } else {
                self.cloudkit = false
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(macNotification, forKey: .macNotification)
            try c.encode(cloudkit, forKey: .cloudkit)
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

    /// Effective channels for an agent. Per-agent overrides were removed — the
    /// global mac + iPhone setting now applies to every agent. The `perAgent`
    /// field is retained in the Codable model only for backward-compatible
    /// decode of pre-existing JSON (cleared by `migrateClearPerAgentOverridesIfNeeded`).
    static func effectiveChannels(for agent: TrackedAgent) -> ChannelConfig {
        load().global
    }

    static func setGlobal(_ config: ChannelConfig) {
        var store = load()
        store.global = config
        save(store)
    }

    /// One-time cleanup of legacy per-agent channel overrides. Safe to call on
    /// every launch; it no-ops after the first run.
    static func migrateClearPerAgentOverridesIfNeeded() {
        let flag = "doomcoder.channels.perAgentOverrides.cleared.v1"
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: flag) else { return }
        var store = load()
        if !store.perAgent.isEmpty {
            store.perAgent = [:]
            save(store)
        }
        ud.set(true, forKey: flag)
    }

}
