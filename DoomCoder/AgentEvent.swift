import Foundation

// MARK: - AgentEvent
//
// Wire format for events received on the Unix domain socket at ~/.doomcoder/dc.sock.
// Hooks (Tier 1) and the doomcoder-mcp binary (Tier 2) both emit one JSON object per line.
// Missing keys default to safe values — any future hook or MCP transport can add fields
// without breaking older DoomCoder versions.

struct AgentEvent: Codable, Sendable {

    enum Source: String, Codable, Sendable {
        case hook
        case mcp
        case manual   // injected by "Send Test Notification" button
    }

    // Single-character status code shared by hook + MCP transports:
    //   s = start          (session started / first tool use)
    //   w = waitForInput   (agent is blocked waiting for the user)
    //   i = info           (progress — no attention required)
    //   e = error          (agent hit an error)
    //   d = done           (session finished cleanly)
    enum Status: String, Codable, Sendable {
        case start    = "s"
        case wait     = "w"
        case info     = "i"
        case error    = "e"
        case done     = "d"

        var displayName: String {
            switch self {
            case .start: return "Started"
            case .wait:  return "Needs input"
            case .info:  return "Working"
            case .error: return "Error"
            case .done:  return "Done"
            }
        }

        // True when the user should be pulled back to the Mac.
        var isAttention: Bool {
            switch self {
            case .wait, .error, .done: return true
            case .start, .info:        return false
            }
        }
    }

    let src: Source
    let agent: String           // "claude-code", "copilot-cli", "cursor", etc.
    let status: Status
    let sessionId: String?      // hook sessionId (Claude) or derived from pid
    let cwd: String?            // working directory (from hook transcript or MCP)
    let tool: String?           // current tool name (PreToolUse / PostToolUse)
    let message: String?        // optional short human-readable string
    let pid: Int32?             // agent process id (MCP)
    let event: String?          // raw hook event name (SessionStart, Stop, etc.)
    let timestamp: Double       // seconds since 1970; set by hook/mcp client

    enum CodingKeys: String, CodingKey {
        case src, agent, status = "s", sessionId = "sid"
        case cwd, tool, message = "m", pid, event, timestamp = "t"
    }

    init(src: Source,
         agent: String,
         status: Status,
         sessionId: String? = nil,
         cwd: String? = nil,
         tool: String? = nil,
         message: String? = nil,
         pid: Int32? = nil,
         event: String? = nil,
         timestamp: Double = Date.now.timeIntervalSince1970)
    {
        self.src = src
        self.agent = agent
        self.status = status
        self.sessionId = sessionId
        self.cwd = cwd
        self.tool = tool
        self.message = message
        self.pid = pid
        self.event = event
        self.timestamp = timestamp
    }

    // MARK: - Decoding with lenient defaults
    //
    // Hook payloads come in many shapes; the hook.sh script normalizes them, but
    // we still guard every field so malformed or partial events never crash.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.src       = (try? c.decode(Source.self, forKey: .src))    ?? .hook
        self.agent     = (try? c.decode(String.self, forKey: .agent))  ?? "unknown"
        self.status    = (try? c.decode(Status.self, forKey: .status)) ?? .info
        self.sessionId = try? c.decode(String.self, forKey: .sessionId)
        self.cwd       = try? c.decode(String.self, forKey: .cwd)
        self.tool      = try? c.decode(String.self, forKey: .tool)
        self.message   = try? c.decode(String.self, forKey: .message)
        self.pid       = try? c.decode(Int32.self,  forKey: .pid)
        self.event     = try? c.decode(String.self, forKey: .event)
        self.timestamp = (try? c.decode(Double.self, forKey: .timestamp)) ?? Date.now.timeIntervalSince1970
    }

    // Canonical session key. Prefer explicit session id, fall back to pid,
    // then to a hash of cwd so different projects/tabs with the same agent
    // don't collapse into one session. Final fallback is the agent name.
    var sessionKey: String {
        if let sid = sessionId, !sid.isEmpty { return "\(agent):\(sid)" }
        if let p = pid { return "\(agent):pid:\(p)" }
        if let c = cwd, !c.isEmpty {
            // Simple stable 32-bit FNV-1a hash — no Foundation dep, no collisions
            // in practice at the small cardinality of open projects per user.
            var h: UInt32 = 0x811c9dc5
            for byte in c.utf8 {
                h ^= UInt32(byte)
                h = h &* 0x01000193
            }
            return "\(agent):cwd:\(String(h, radix: 16))"
        }
        return "\(agent):default"
    }
}

// MARK: - JSON line framing

enum AgentEventCodec {
    // Parses one or more newline-delimited JSON objects from a raw byte buffer.
    // Returns parsed events plus any remainder (incomplete trailing line) to carry over.
    static func decode(buffer: inout Data) -> [AgentEvent] {
        var events: [AgentEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A /* \n */) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            if let ev = try? JSONDecoder().decode(AgentEvent.self, from: line) {
                events.append(ev)
            }
        }
        return events
    }

    static func encode(_ event: AgentEvent) -> Data {
        (try? JSONEncoder().encode(event)) ?? Data()
    }
}
