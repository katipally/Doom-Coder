// dc-hook — DoomCoder helper binary invoked by AI-agent hooks.
// Forwards the stdin JSON to the DoomCoder app via a unix-domain socket.
// Exits 0 silently if DoomCoder isn't running, so it never wedges an agent.
// Usage:
//   dc-hook <agent> <event>            (positional args — v2 format)
//   dc-hook --agent claude --event Stop  (flag args — v1 compat)
//   dc-hook --ping                     (for wizard Gate A verification)
//   dc-hook --replay-demo <agent>      (synthetic 30s lifecycle for testing)
import Foundation
#if canImport(Darwin)
import Darwin
#endif

let kVersion = "1"
let kSocketName = "hook.sock"
let kPauseFileName = "paused"
let kSupportDirName = "DoomCoder"
let kHardTimeoutSeconds: UInt32 = 5

func supportDir() -> String {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    return "\(home)/Library/Application Support/\(kSupportDirName)"
}

func socketPath() -> String { "\(supportDir())/\(kSocketName)" }
func pausePath()  -> String { "\(supportDir())/\(kPauseFileName)" }

func isPaused() -> Bool { FileManager.default.fileExists(atPath: pausePath()) }

func argValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func flagPresent(_ name: String) -> Bool { CommandLine.arguments.contains("--\(name)") }

/// Parse positional args: dc-hook <agent> <event>
func positionalArgs() -> (agent: String, event: String)? {
    let args = CommandLine.arguments.filter { !$0.hasPrefix("--") }
    // args[0] = binary path, args[1] = agent, args[2] = event
    guard args.count >= 3 else { return nil }
    return (args[1], args[2])
}

// Frame: 4-byte big-endian length || UTF-8 JSON bytes
func sendFrame(_ data: Data) -> Bool {
    let path = socketPath()
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return false }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
            _ = pathBytes.withUnsafeBufferPointer { src in
                memcpy(dst, src.baseAddress, pathBytes.count)
            }
        }
    }

    var tv = timeval(tv_sec: 0, tv_usec: 400_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let sz = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in connect(fd, sp, sz) }
    }
    if connected != 0 { return false }

    var lenBE = UInt32(data.count).bigEndian
    var ok = true
    _ = withUnsafeBytes(of: &lenBE) { buf -> Int in
        let n = send(fd, buf.baseAddress, 4, 0); if n != 4 { ok = false }; return n
    }
    if !ok { return false }
    let written = data.withUnsafeBytes { buf -> Int in send(fd, buf.baseAddress, data.count, 0) }
    return written == data.count
}

func sendEnvelope(agent: String, event: String, payload: Any = [:] as [String: Any], synthetic: Bool = false) -> Bool {
    var envelope: [String: Any] = [
        "v": kVersion,
        "agent": agent,
        "event": event,
        "cwd": FileManager.default.currentDirectoryPath,
        "pid": Int(getpid()),
        "ts": Date().timeIntervalSince1970,
        "payload": payload
    ]
    if synthetic { envelope["synthetic"] = true }
    guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: []) else { return false }
    return sendFrame(data)
}

// MARK: - Replay demo (30s synthetic lifecycle)

func replayDemo(agent: String) -> Int32 {
    let demoEvents: [(String, Int)] // (event, delay_seconds)
    switch agent {
    case "claude":
        demoEvents = [
            ("SessionStart", 0),
            ("Notification", 5),
            ("SubagentStop", 10),
            ("Notification", 15),
            ("Stop", 25)
        ]
    case "cursor":
        demoEvents = [
            ("sessionStart", 0),
            ("afterAgentResponse", 8),
            ("afterAgentResponse", 16),
            ("stop", 25)
        ]
    case "vscode":
        demoEvents = [
            ("SessionStart", 0),
            ("Notification", 8),
            ("Stop", 25)
        ]
    case "copilot_cli":
        demoEvents = [
            ("sessionStart", 0),
            ("userPromptSubmitted", 5),
            ("userPromptSubmitted", 12),
            ("errorOccurred", 20),
            ("sessionEnd", 25)
        ]
    default:
        demoEvents = [("sessionStart", 0), ("stop", 10)]
    }

    let sessionId = "demo-\(UUID().uuidString.prefix(8))"
    var lastTime = 0

    for (event, delay) in demoEvents {
        let wait = delay - lastTime
        if wait > 0 { sleep(UInt32(wait)) }
        lastTime = delay

        let payload: [String: Any] = [
            "session_id": sessionId,
            "synthetic": true,
            "demo": true
        ]
        if !sendEnvelope(agent: agent, event: event, payload: payload, synthetic: true) {
            // Socket not available — DoomCoder might not be running
            fputs("warning: could not reach DoomCoder socket for event \(event)\n", stderr)
        }
    }
    return 0
}

func runMain() -> Int32 {
    // Don't use hard alarm for demos (they take 30s)
    if !flagPresent("replay-demo") {
        signal(SIGALRM) { _ in _exit(0) }
        alarm(kHardTimeoutSeconds)
    }

    // --replay-demo <agent>
    if let demoAgent = argValue("replay-demo") {
        return replayDemo(agent: demoAgent)
    }

    if isPaused() { return 0 }

    // Resolve agent/event from positional args (v2) or flags (v1 compat)
    let agent: String
    let event: String
    if let pos = positionalArgs() {
        agent = pos.agent
        event = pos.event
    } else {
        agent = argValue("agent") ?? "unknown"
        event = argValue("event") ?? "unknown"
    }

    var payloadJSON: Any = [:]
    if flagPresent("ping") {
        payloadJSON = ["kind": "ping"]
    } else {
        let handle = FileHandle.standardInput
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            payloadJSON = obj
        } else if let s = String(data: data, encoding: .utf8), !s.isEmpty {
            payloadJSON = ["raw": s]
        }
    }

    _ = sendEnvelope(agent: agent, event: event, payload: payloadJSON)
    return 0
}

exit(runMain())
