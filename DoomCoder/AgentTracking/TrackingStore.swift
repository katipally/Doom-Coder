import Foundation

// Per-agent "send me notifications about this agent" toggle.
// Separate from AgentInstallerV2 (which is about whether hooks are installed)
// and ChannelStore (which is about *where* notifications go).
//
// Default for a freshly-installed agent: tracking ON.
enum TrackingStore {
    private static let key = "doomcoder.tracking.enabled.v1"

    static func isEnabled(_ agent: TrackedAgent) -> Bool {
        let map = load()
        return map[agent.rawValue] ?? true
    }

    static func setEnabled(_ agent: TrackedAgent, _ on: Bool) {
        var map = load()
        map[agent.rawValue] = on
        save(map)
    }

    static func enabledCount() -> Int {
        let map = load()
        return TrackedAgent.allCases.filter { map[$0.rawValue] ?? true }.count
    }

    private static func load() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
    }

    private static func save(_ map: [String: Bool]) {
        UserDefaults.standard.set(map, forKey: key)
    }
}
