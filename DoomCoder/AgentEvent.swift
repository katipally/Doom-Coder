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

        /// Deterministic, user-facing notification body. We intentionally
        /// ignore whatever the agent wrote in `message` so every ntfy push
        /// reads the same regardless of which agent / prompt emitted it —
        /// agents only have to send the single letter (token-cheap), and
        /// DoomCoder fills in the copy.
        var canonicalBody: String {
            switch self {
            case .start: return "Agent started working"
            case .wait:  return "Needs your input"
            case .info:  return "Working…"
            case .error: return "Hit an error"
            case .done:  return "Task complete"
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
    let tty: String?            // controlling terminal (e.g. "/dev/ttys003") — for multi-tab CLIs
    let nonce: String?          // set by round-trip hook test; passthrough only
    let timestamp: Double       // seconds since 1970; set by hook/mcp client

    enum CodingKeys: String, CodingKey {
        case src, agent, status = "s", sessionId = "sid"
        case cwd, tool, message = "m", pid, event, tty, nonce
        case timestamp = "t"
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
         tty: String? = nil,
         nonce: String? = nil,
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
        self.tty = tty
        self.nonce = nonce
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
        self.tty       = try? c.decode(String.self, forKey: .tty)
        self.nonce     = try? c.decode(String.self, forKey: .nonce)
        self.timestamp = (try? c.decode(Double.self, forKey: .timestamp)) ?? Date.now.timeIntervalSince1970
    }

    // Canonical session key. Prefer explicit session id, then pid, then
    // (tty, cwd) for multi-tab CLIs, then cwd-hash, then agent name.
    //
    // The tty fallback is what distinguishes two Copilot CLI tabs in the same
    // login shell tree: tabs always have distinct ttys even when $PPID collides.
    var sessionKey: String {
        if let sid = sessionId, !sid.isEmpty { return "\(agent):\(sid)" }
        if let p = pid { return "\(agent):pid:\(p)" }
        if let t = tty, !t.isEmpty {
            // Include cwd hash when available so the same tty in two shells
            // (e.g. after `ssh` session swap) doesn't collapse.
            let last = t.split(separator: "/").last.map(String.init) ?? t
            if let c = cwd, !c.isEmpty {
                return "\(agent):tty:\(last):\(fnv1a32(c))"
            }
            return "\(agent):tty:\(last)"
        }
        if let c = cwd, !c.isEmpty {
            return "\(agent):cwd:\(fnv1a32(c))"
        }
        return "\(agent):default"
    }

    // Simple 32-bit FNV-1a hash — no Foundation dep.
    private func fnv1a32(_ s: String) -> String {
        var h: UInt32 = 0x811c9dc5
        for byte in s.utf8 {
            h ^= UInt32(byte)
            h = h &* 0x01000193
        }
        return String(h, radix: 16)
    }
}

// MARK: - JSON line framing

enum AgentEventCodec {
    // Hard limits: any single line over this is dropped.
    static let maxLineBytes = 32 * 1024

    // Parses one or more newline-delimited JSON objects from a raw byte buffer.
    // Returns parsed events plus any remainder (incomplete trailing line) to carry over.
    // Guarantees: never crashes on malformed input, non-UTF8 bytes, oversized
    // lines, or non-JSON content. Silently drops invalid lines.
    static func decode(buffer: inout Data) -> [AgentEvent] {
        var events: [AgentEvent] = []
        let decoder = JSONDecoder()
        while let newline = buffer.firstIndex(of: 0x0A /* \n */) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, line.count <= maxLineBytes else { continue }
            // Line must be valid UTF-8 and start with `{` (JSON object). Any
            // other first byte (e.g. garbage from a crashed child) is dropped.
            guard line.first == 0x7B /* { */ else { continue }
            guard String(data: Data(line), encoding: .utf8) != nil else { continue }
            if let ev = try? decoder.decode(AgentEvent.self, from: line) {
                events.append(ev)
            }
        }
        return events
    }

    static func encode(_ event: AgentEvent) -> Data {
        (try? JSONEncoder().encode(event)) ?? Data()
    }
}
