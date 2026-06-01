import Foundation

/// Single source of truth for notification title/body strings. Both Mac
/// (NotificationDispatcher) and iOS (NSE) render through these helpers so
/// the user sees byte-identical copy on both devices.
public enum NotificationCopy {

    public struct EventContext: Sendable {
        public let agent: TrackedAgent
        public let phase: NormalizedEventPhase
        public let lastTool: String?
        public let cwdBase: String?      // last path component of cwd
        public let durationSeconds: Int? // wall-clock seconds since sessionStart

        public init(agent: TrackedAgent,
                    phase: NormalizedEventPhase,
                    lastTool: String? = nil,
                    cwdBase: String? = nil,
                    durationSeconds: Int? = nil) {
            self.agent = agent
            self.phase = phase
            self.lastTool = lastTool
            self.cwdBase = cwdBase
            self.durationSeconds = durationSeconds
        }
    }

    public static func title(_ ev: EventContext) -> String {
        let name = ev.agent.displayName
        switch ev.phase {
        case .sessionStart:        return "\(name) · started"
        case .sessionEnd:          return "\(name) · done"
        case .error, .toolError:   return "\(name) · failed"
        case .permissionNeeded:    return "\(name) · needs you"
        case .fileEdit:            return "\(name) · edited a file"
        case .compaction:          return "\(name) · compacting context"
        case .thinking:            return "\(name) · thinking"
        case .housekeeping:        return "\(name) · update"
        case .userPrompt:          return "\(name) · prompt sent"
        default:                   return name
        }
    }

    public static func body(_ ev: EventContext) -> String {
        let dur = ev.durationSeconds.flatMap(formatDuration)
        switch ev.phase {
        case .sessionStart:
            return ev.cwdBase.map { "Started in \($0)" } ?? "Started"
        case .sessionEnd:
            if let tool = ev.lastTool, !tool.isEmpty {
                return dur.map { "Finished using \(tool) · \($0)" } ?? "Finished using \(tool)"
            }
            if let cwd = ev.cwdBase {
                return dur.map { "Finished in \(cwd) · \($0)" } ?? "Finished in \(cwd)"
            }
            return dur.map { "Finished · \($0)" } ?? "Finished"
        case .error, .toolError:
            if let tool = ev.lastTool, !tool.isEmpty {
                return dur.map { "Failed in \(tool) · \($0)" } ?? "Failed in \(tool)"
            }
            return dur.map { "Failed · \($0)" } ?? "Failed"
        case .permissionNeeded:
            if let tool = ev.lastTool, !tool.isEmpty {
                return "Waiting for your approval · \(tool)"
            }
            return "Waiting for your approval"
        case .fileEdit:
            return ev.lastTool.flatMap { $0.isEmpty ? nil : "Edited \($0)" }
                ?? (ev.cwdBase.map { "Edited a file in \($0)" } ?? "Edited a file")
        case .compaction:
            return "Compacting the conversation context"
        case .thinking:
            return ev.cwdBase.map { "Thinking in \($0)" } ?? "Thinking through the next step"
        case .housekeeping:
            return ev.cwdBase.map { "Workspace update in \($0)" } ?? "Workspace update"
        case .userPrompt:
            return ev.cwdBase.map { "You sent a prompt in \($0)" } ?? "You sent a prompt"
        default:
            return ev.agent.displayName
        }
    }

    private static func formatDuration(_ secs: Int) -> String? {
        guard secs > 1 else { return nil }
        let m = secs / 60
        let s = secs % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    /// Short last-path-component for a cwd string. Used by both Mac (when
    /// publishing) and iOS (when rendering from inlined APNs payload).
    public static func shortCwd(_ cwd: String) -> String? {
        let t = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let last = (t as NSString).lastPathComponent
        return last.isEmpty ? nil : last
    }
}
