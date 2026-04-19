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

    /// Counts agents that are BOTH installed (hooks present) AND tracking-enabled.
    /// This is the correct numerator for "X of Y tracked" subtitle.
    static func installedAndEnabledCount() -> Int {
        let map = load()
        return TrackedAgent.allCases.filter { agent in
            let enabled = map[agent.rawValue] ?? true
            guard enabled else { return false }
            if agent == .copilotCLI {
                return !CopilotCLIFolderManager.installedFolders().isEmpty
            }
            return AgentInstallerV2.isInstalled(agent)
        }.count
    }

    /// Number of agents with hooks installed (regardless of tracking toggle).
    static func installedCount() -> Int {
        TrackedAgent.allCases.filter { agent in
            if agent == .copilotCLI {
                return !CopilotCLIFolderManager.installedFolders().isEmpty
            }
            return AgentInstallerV2.isInstalled(agent)
        }.count
    }

    /// Number of agents detected on the system (app exists, not necessarily hooks installed).
    static func detectedCount() -> Int {
        AgentDetector.detectAll().filter(\.installed).count
    }

    private static func load() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
    }

    private static func save(_ map: [String: Bool]) {
        UserDefaults.standard.set(map, forKey: key)
    }
}
