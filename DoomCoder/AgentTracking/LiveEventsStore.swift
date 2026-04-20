import SwiftUI
import Observation

// Session-only rolling buffer of raw hook events per agent.
// Events are never persisted — cleared on app restart.
// UI observes this for the Live Events panel in Configure Agents.
@MainActor
@Observable
final class LiveEventsStore {
    static let shared = LiveEventsStore()

    private static let maxPerAgent = 100

    /// Events grouped by agent, newest last (append order).
    private(set) var eventsByAgent: [TrackedAgent: [LiveEvent]] = [:]

    private init() {}

    func append(_ envelope: HookEnvelope) {
        guard let agent = TrackedAgent(rawValue: envelope.agent) else { return }
        var list = eventsByAgent[agent] ?? []
        list.append(LiveEvent(envelope: envelope))
        if list.count > Self.maxPerAgent {
            list.removeFirst(list.count - Self.maxPerAgent)
        }
        withAnimation(DCAnim.snap) {
            eventsByAgent[agent] = list
        }
    }

    func clear(agent: TrackedAgent) {
        withAnimation(DCAnim.fade) {
            eventsByAgent[agent] = []
        }
    }

    func events(for agent: TrackedAgent) -> [LiveEvent] {
        eventsByAgent[agent] ?? []
    }
}

// MARK: - LiveEvent

struct LiveEvent: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let agent: String
    let event: String
    let cwd: String
    let synthetic: Bool
    let payloadJSON: String?

    init(envelope: HookEnvelope) {
        self.id = UUID()
        self.timestamp = Date(timeIntervalSince1970: envelope.ts)
        self.agent = envelope.agent
        self.event = envelope.event
        self.cwd = envelope.cwd
        self.synthetic = envelope.synthetic
        if let raw = envelope.payloadRaw,
           let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: pretty, encoding: .utf8) {
            self.payloadJSON = str
        } else {
            self.payloadJSON = nil
        }
    }

    /// HH:mm:ss formatted timestamp for compact display.
    var timeLabel: String {
        let cal = Calendar.current
        let h = cal.component(.hour, from: timestamp)
        let m = cal.component(.minute, from: timestamp)
        let s = cal.component(.second, from: timestamp)
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Shortened cwd for display (last 2 path components).
    var shortCwd: String {
        guard !cwd.isEmpty else { return "" }
        let parts = cwd.split(separator: "/")
        guard parts.count >= 2 else { return cwd }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }
}
