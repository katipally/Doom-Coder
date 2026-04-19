import Foundation

// The JSON envelope written by dc-hook to the unix socket.
// Keep in lock-step with dc-hook/main.swift.
struct HookEnvelope: Sendable {
    let v: String
    let agent: String
    let event: String
    let cwd: String
    let pid: Int
    let ts: TimeInterval
    let payloadRaw: Data?

    var payloadDict: [String: Any]? {
        guard let d = payloadRaw else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func decode(_ data: Data) -> HookEnvelope? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let v = obj["v"] as? String,
              let agent = obj["agent"] as? String,
              let event = obj["event"] as? String else { return nil }
        let cwd = (obj["cwd"] as? String) ?? ""
        let pid = (obj["pid"] as? Int) ?? 0
        let ts = (obj["ts"] as? TimeInterval) ?? Date().timeIntervalSince1970
        var payloadRaw: Data? = nil
        if let p = obj["payload"] {
            payloadRaw = try? JSONSerialization.data(withJSONObject: p, options: [])
        }
        return HookEnvelope(v: v, agent: agent, event: event, cwd: cwd, pid: pid, ts: ts, payloadRaw: payloadRaw)
    }
}

// App-side session lifecycle derived from heterogeneous hook events.
enum AgentSessionState: String, Sendable {
    case running
    case waitingInput     = "waiting_input"
    case waitingApproval  = "waiting_approval"
    case completed
    case failed

    var humanReadable: String {
        switch self {
        case .running:          return "running"
        case .waitingInput:     return "waiting for input"
        case .waitingApproval:  return "waiting for approval"
        case .completed:        return "completed"
        case .failed:           return "failed"
        }
    }
}

enum TrackedAgent: String, CaseIterable, Sendable {
    case claude
    case cursor
    case vscode
    case copilotCLI = "copilot_cli"

    var displayName: String {
        switch self {
        case .claude:     return "Claude Code"
        case .cursor:     return "Cursor"
        case .vscode:     return "VS Code Copilot"
        case .copilotCLI: return "Copilot CLI"
        }
    }
}
