import Foundation

// MARK: - MCPRoundTripTest
//
// Real, end-to-end verification for the MCP pipeline. Replaces the previous
// fake `.dcVerifySetup` / `injectTest` paths that merely posted a synthetic
// notification.
//
// Two gates:
//
//   • selfTest — DoomCoder spawns `/usr/bin/python3 mcp.py --agent __dc_st__`
//     itself, drives the `initialize` JSON-RPC over stdio, and waits for the
//     resulting `mcp-hello` to land on `~/.doomcoder/dc.sock`. This proves
//     the script + socket pipeline works *before* we trust the agent to do
//     the same thing. Runs in ~100–300ms.
//
//   • awaitAgentHandshake — After the user writes the config into their
//     real agent (Cursor / Claude Code / Copilot CLI / …), we poll
//     AgentStatusManager.mcpHelloAt for a fresh timestamp newer than a
//     baseline. This is the ground-truth "the agent loaded our config"
//     signal. Deterministic, agent-side, zero guessing.
//
//   • awaitFirstToolCall — Optional second gate. Waits for the first real
//     `dc` tool call from the agent (not a hello), proving the rules file
//     was actually read and the agent honored the lifecycle instructions.
//     Used by Setup's "Verify" step to show a second green tick.
//
// All APIs return a `Result<Success, Failure>` with tight, user-facing
// error messages.

@MainActor
enum MCPRoundTripTest {

    enum Failure: Error, LocalizedError {
        case scriptMissing(String)
        case spawnFailed(String)
        case handshakeTimeout
        case toolCallTimeout
        case socketNotRunning
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .scriptMissing(let p):
                return "MCP script not found at \(p). DoomCoder redeploys it on launch — try restarting the app."
            case .spawnFailed(let msg):
                return "Couldn't launch the MCP script: \(msg)"
            case .handshakeTimeout:
                return "The agent never sent an `initialize` RPC. Make sure you fully quit and reopened the app (Cmd+Q, not just the window)."
            case .toolCallTimeout:
                return "Config loaded, but the agent never called `dc` — the rules snippet may not have been read. Try a fresh chat / session."
            case .socketNotRunning:
                return "DoomCoder's local socket isn't accepting connections. Restart DoomCoder and retry."
            case .invalidResponse(let msg):
                return "Unexpected MCP response: \(msg)"
            }
        }
    }

    struct Success {
        let millis: Int
        /// Client name the agent reported in its `initialize` request
        /// (e.g. "Cursor", "Claude Code", "GitHub Copilot CLI"). Empty for
        /// self-test where we set it ourselves.
        let clientName: String
    }

    // MARK: - selfTest
    //
    // Spawns our own mcp.py subprocess and pushes an `initialize` RPC into
    // its stdin. The script emits a synthetic `mcp-hello` event over the
    // socket before replying on stdout. We only need the socket side to
    // consider the script healthy — stdout is for the MCP client (which is
    // us, briefly, during the test).
    //
    // Uses the reserved agent id `__dc_st__` so the hello can be filtered
    // out of the UI and never shows up as a session row.

    private static let selfTestAgent = "__dc_st__"

    static func selfTest(
        statusManager: AgentStatusManager,
        timeout: TimeInterval = 5.0
    ) async -> Result<Success, Failure> {
        let scriptURL = MCPRuntime.scriptURL
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            return .failure(.scriptMissing(scriptURL.path))
        }

        let installId = "st-" + UUID().uuidString
        let baseline = statusManager.lastHello(for: selfTestAgent) ?? .distantPast
        let start = Date.now

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [scriptURL.path, "--agent", selfTestAgent, "--install-id", installId]
        let stdin  = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput  = stdin
        proc.standardOutput = stdout
        proc.standardError  = stderr

        do {
            try proc.run()
        } catch {
            return .failure(.spawnFailed(error.localizedDescription))
        }

        // Send an `initialize` RPC so mcp.py emits its hello. We include a
        // synthetic clientInfo.name so the hello carries a recognisable
        // marker if anyone looks at the Install Anywhere "last client" field.
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "DoomCoder Self-Test", "version": "1"]
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: initialize),
           let line = String(data: data, encoding: .utf8) {
            try? stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        }

        // Poll the AgentStatusManager for a fresh hello. The server may take
        // ~100ms to start on cold boot.
        let deadline = start.addingTimeInterval(timeout)
        while Date.now < deadline {
            if let last = statusManager.lastHello(for: selfTestAgent), last > baseline {
                try? stdin.fileHandleForWriting.close()
                proc.terminate()
                let ms = Int(Date.now.timeIntervalSince(start) * 1000)
                return .success(Success(millis: max(ms, 0), clientName: "DoomCoder Self-Test"))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? stdin.fileHandleForWriting.close()
        proc.terminate()
        // If the process exited immediately, the error is almost certainly
        // a Python import / permission issue — surface stderr to the user.
        let errData = try? stderr.fileHandleForReading.readToEnd()
        if let errData, let s = String(data: errData, encoding: .utf8), !s.isEmpty {
            return .failure(.spawnFailed(String(s.prefix(200))))
        }
        return .failure(.handshakeTimeout)
    }

    // MARK: - awaitAgentHandshake
    //
    // After the user writes the MCP config into the real agent and restarts
    // it, we poll for a fresh hello on the agent's own id. No subprocess
    // involvement — the agent must have genuinely loaded the config and
    // spawned its own copy of mcp.py for this to succeed.

    static func awaitAgentHandshake(
        agentId: String,
        since baseline: Date,
        timeout: TimeInterval,
        statusManager: AgentStatusManager
    ) async -> Result<Success, Failure> {
        let start = Date.now
        let deadline = start.addingTimeInterval(timeout)
        while Date.now < deadline {
            if let last = statusManager.lastHello(for: agentId), last > baseline {
                let clientName = MCPInstaller.lastClientName(for: agentId) ?? ""
                let ms = Int(last.timeIntervalSince(start) * 1000)
                return .success(Success(millis: max(ms, 0), clientName: clientName))
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return .failure(.handshakeTimeout)
    }

    // MARK: - awaitFirstToolCall
    //
    // Waits for the first *real* `dc` call from the agent (i.e., a non-hello
    // event after `baseline`). This is the "rules were honored" signal.

    static func awaitFirstToolCall(
        agentId: String,
        since baseline: Date,
        timeout: TimeInterval,
        statusManager: AgentStatusManager
    ) async -> Result<Success, Failure> {
        let start = Date.now
        let deadline = start.addingTimeInterval(timeout)
        while Date.now < deadline {
            if let last = statusManager.lastToolCall(for: agentId), last > baseline {
                let ms = Int(last.timeIntervalSince(start) * 1000)
                return .success(Success(millis: max(ms, 0), clientName: ""))
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return .failure(.toolCallTimeout)
    }
}
