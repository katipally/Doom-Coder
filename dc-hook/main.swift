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
let kSupportDirName = "DoomCoder"
let kHardTimeoutSeconds: UInt32 = 5

func supportDir() -> String {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    return "\(home)/Library/Application Support/\(kSupportDirName)"
}

func socketPath() -> String { "\(supportDir())/\(kSocketName)" }

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

    // Tight timeouts: total budget ≤ 150ms so a dead DoomCoder can never
    // wedge an agent. 75ms each for send/recv, 50ms for non-blocking connect.
    var tv = timeval(tv_sec: 0, tv_usec: 75_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    let sz = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connRC = withUnsafePointer(to: &addr) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in connect(fd, sp, sz) }
    }
    if connRC != 0 {
        if errno != EINPROGRESS { return false }
        var wfds = fd_set()
        let wfdsPtr = withUnsafeMutablePointer(to: &wfds) { $0 }
        memset(wfdsPtr, 0, MemoryLayout<fd_set>.size)
        let idx = Int(fd / 32)
        let bit = Int32(1) << (fd % 32)
        withUnsafeMutableBytes(of: &wfds) { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: Int32.self)
            p[idx] |= bit
        }
        var ctv = timeval(tv_sec: 0, tv_usec: 50_000)
        let nr = select(fd + 1, nil, &wfds, nil, &ctv)
        if nr <= 0 { return false }
        var soErr: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soLen) != 0 || soErr != 0 { return false }
    }
    _ = fcntl(fd, F_SETFL, flags)

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
    // Use parent PID — dc-hook is a new process per invocation, so getpid()
    // yields a different value every time. getppid() returns the agent
    // process that invoked us, giving a stable identity within a session.
    var envelope: [String: Any] = [
        "v": kVersion,
        "agent": agent,
        "event": event,
        "cwd": FileManager.default.currentDirectoryPath,
        "pid": Int(getppid()),
        "ts": Date().timeIntervalSince1970,
        "payload": payload
    ]
    if synthetic { envelope["synthetic"] = true }
    guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: []) else { return false }
    return sendFrame(data)
}

// MARK: - Process-tree agent identification
//
// Replaces brittle env-var dedup (Claude in VSCode terminal often missed
// CLAUDE_CODE_ENTRY_POINT; VSCODE_PID leaks into Cursor; Copilot CLI had no
// case). Walks the PPID chain via libproc and matches against per-agent
// patterns. Pure C system calls — total budget ≤ a few ms.

// proc_pidpath / proc_pidinfo signatures (from <libproc.h>).
// We declare them via @_silgen_name to avoid an extra bridging header.
@_silgen_name("proc_pidpath")
private func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32

// Mirrors struct proc_bsdshortinfo from <sys/proc_info.h> exactly.
// Field ORDER must match the C layout — Swift struct fields have no padding
// reordering, so any mismatch silently corrupts every field read via
// proc_pidinfo(PROC_PIDT_SHORTBSDINFO). Total size: 64 bytes.
// Layout: pid(4), ppid(4), pgid(4), status(4), comm(16), flags(4),
//         uid(4), gid(4), ruid(4), rgid(4), svuid(4), svgid(4), rfu1(4)
private struct DCProcBSDShortInfo {
    var pbsi_pid: UInt32 = 0      // offset  0
    var pbsi_ppid: UInt32 = 0     // offset  4
    var pbsi_pgid: UInt32 = 0     // offset  8
    var pbsi_status: UInt32 = 0   // offset 12
    var pbsi_comm: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) =
        (0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0) // offset 16, 16 bytes (MAXCOMLEN)
    var pbsi_flags: UInt32 = 0    // offset 32
    var pbsi_uid: UInt32 = 0      // offset 36
    var pbsi_gid: UInt32 = 0      // offset 40
    var pbsi_ruid: UInt32 = 0     // offset 44
    var pbsi_rgid: UInt32 = 0     // offset 48
    var pbsi_svuid: UInt32 = 0    // offset 52
    var pbsi_svgid: UInt32 = 0    // offset 56
    var pbsi_rfu1: UInt32 = 0     // offset 60
}

@_silgen_name("proc_pidinfo")
private func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64,
                           _ buffer: UnsafeMutableRawPointer, _ buffersize: Int32) -> Int32

private let PROC_PIDT_SHORTBSDINFO: Int32 = 13

private func procShortInfo(_ pid: Int32) -> DCProcBSDShortInfo? {
    var info = DCProcBSDShortInfo()
    let size = Int32(MemoryLayout<DCProcBSDShortInfo>.size)
    let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
        proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, UnsafeMutableRawPointer(ptr), size)
    }
    guard rc == size else { return nil }
    return info
}

private func psComm(_ pid: Int32) -> String? {
    // Prefer full executable path (proc_pidpath) so we can match
    // ".../claude/cli.js" style ancestors; fall back to short comm.
    var buf = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
    let rc = buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
        proc_pidpath(pid, UnsafeMutableRawPointer(ptr.baseAddress!), UInt32(ptr.count))
    }
    if rc > 0 {
        let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
    }
    guard let info = procShortInfo(pid) else { return nil }
    let s: String = withUnsafePointer(to: info.pbsi_comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
    }
    return s.isEmpty ? nil : s
}

private func parentPID(of pid: Int32) -> Int32? {
    guard let info = procShortInfo(pid) else { return nil }
    return Int32(info.pbsi_ppid)
}

private func ancestorChain(maxDepth: Int = 6) -> [String] {
    var chain: [String] = []
    var pid: Int32 = getppid()
    var depth = 0
    while pid > 1 && depth < maxDepth {
        if let c = psComm(pid) { chain.append(c.lowercased()) }
        guard let pp = parentPID(of: pid), pp > 0, pp != pid else { break }
        pid = pp
        depth += 1
    }
    return chain
}

private func chainContains(_ chain: [String], anyOf needles: [String]) -> Bool {
    for c in chain {
        let last = (c.split(separator: "/").last.map(String.init) ?? c).lowercased()
        for n in needles {
            let nl = n.lowercased()
            if c.contains(nl) || last.contains(nl) { return true }
        }
    }
    return false
}

// Returns the command-line arguments of the given PID using KERN_PROCARGS2.
// Used to detect Claude Desktop internal sub-agents (--allowed-tools mcp__computer-use__*).
private func procArgs(_ pid: Int32) -> [String] {
    // CTL_KERN=1, KERN_ARGMAX=8, KERN_PROCARGS2=49 (from <sys/sysctl.h>)
    var argmaxMib: [Int32] = [1, 8]
    var argmax = 0
    var argmaxSize = size_t(MemoryLayout<Int>.size)
    sysctl(&argmaxMib, 2, &argmax, &argmaxSize, nil, 0)
    if argmax <= 0 { argmax = 4096 }

    var mib: [Int32] = [1, 49, pid]
    var buf = [UInt8](repeating: 0, count: argmax)
    var size = size_t(argmax)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }

    // First 4 bytes = argc (int32 little-endian on Apple Silicon & Intel)
    var argc: Int32 = 0
    withUnsafeMutableBytes(of: &argc) { dst in
        dst.copyBytes(from: buf.prefix(4))
    }
    guard argc > 0 else { return [] }

    // Skip the exec-path string (first null-terminated string after argc bytes)
    var i = 4
    while i < Int(size) && buf[i] != 0 { i += 1 }
    while i < Int(size) && buf[i] == 0 { i += 1 }

    // Parse exactly argc argument strings
    var args: [String] = []
    var start = i
    var collected = 0
    while i < Int(size) && collected < Int(argc) {
        if buf[i] == 0 {
            if i > start {
                let bytes = Array(buf[start..<i])
                if let s = String(bytes: bytes, encoding: .utf8), !s.isEmpty {
                    args.append(s)
                    collected += 1
                }
            }
            start = i + 1
        }
        i += 1
    }
    return args
}

// Per-agent ancestor patterns. Matching is case-insensitive substring on
// either the full comm string or its trailing path component.
//
// Extension-invoked CLIs (e.g. Claude Code VS Code extension, Codex extension):
// When a CLI is launched by a VS Code/Cursor extension, the process tree is:
//   dc-hook → claude/codex → extension-host → Code Helper → Code.app
// The CLI is dc-hook's direct parent, so kClaudePatterns / kCodexPatterns
// match on hop 0 — the disqualifier never fires. Hooks work correctly
// whether the CLI is started from a standalone terminal or via an extension.
private let kClaudePatterns:    [String] = ["claude", "anthropic"]
private let kCursorPatterns:    [String] = ["cursor"]
private let kVSCodePatterns:    [String] = ["code helper", "/code", "vscode", "visual studio code"]
private let kCopilotCLIPatterns:[String] = ["gh-copilot", "copilot-cli", " copilot", "/copilot", "gh "]
private let kWindsurfPatterns:  [String] = ["windsurf"]
private let kCodexPatterns:     [String] = ["codex"]

// Patterns that disqualify a "vscode" claim if found in the chain — these are
// other agents whose hooks happen to share the vscode hook config files.
private let kVSCodeDisqualifiers: [String] = ["claude", "cursor", "gh-copilot", "codex", "windsurf"]

func shouldSkipDueToCrossAgent(declaredAgent: String) -> Bool {
    let chain = ancestorChain()
    // No chain (race / sandbox) → don't skip; defer to app-layer dedup.
    if chain.isEmpty { return false }

    switch declaredAgent {
    case "claude":
        // Must look like a claude CLI invocation.
        if !chainContains(chain, anyOf: kClaudePatterns) { return true }
        // Skip hooks fired by Claude Desktop's internal computer-use sub-agents.
        // Those sessions are always spawned with --allowed-tools containing
        // mcp__computer-use__* and are unrelated to the user's Claude Code work.
        let parentArgs = procArgs(getppid())
        if parentArgs.contains(where: { $0.contains("mcp__computer-use") }) { return true }
        return false
    case "cursor":
        return !chainContains(chain, anyOf: kCursorPatterns)
    case "vscode":
        // Must look like VS Code AND must not contain another agent in the chain.
        if !chainContains(chain, anyOf: kVSCodePatterns) { return true }
        if chainContains(chain, anyOf: kVSCodeDisqualifiers) { return true }
        return false
    case "copilot_cli":
        return !chainContains(chain, anyOf: kCopilotCLIPatterns)
    case "windsurf":
        return !chainContains(chain, anyOf: kWindsurfPatterns)
    case "codex_cli":
        return !chainContains(chain, anyOf: kCodexPatterns)
    default:
        return false
    }
}

// MARK: - Replay demo (30s synthetic lifecycle)

func replayDemo(agent: String) -> Int32 {
    let demoEvents: [(String, Int)] // (event, delay_seconds)
    switch agent {
    case "claude":
        demoEvents = [
            ("SessionStart", 0),
            ("UserPromptSubmit", 2),
            ("PreToolUse", 4),
            ("PostToolUse", 6),
            ("FileChanged", 8),
            ("Notification", 10),
            ("SubagentStart", 12),
            ("SubagentStop", 14),
            ("PreToolUse", 16),
            ("PostToolUse", 18),
            ("TaskCompleted", 22),
            ("SessionEnd", 25)
        ]
    case "cursor":
        demoEvents = [
            ("sessionStart", 0),
            ("beforeSubmitPrompt", 2),
            ("preToolUse", 4),
            ("postToolUse", 6),
            ("afterFileEdit", 8),
            ("beforeShellExecution", 10),
            ("afterShellExecution", 12),
            ("afterAgentThought", 16),
            ("afterAgentResponse", 20),
            ("sessionEnd", 25)
        ]
    case "vscode":
        demoEvents = [
            ("SessionStart", 0),
            ("PreToolUse", 4),
            ("PostToolUse", 8),
            ("SubagentStart", 12),
            ("SubagentStop", 16),
            ("SessionEnd", 25)
        ]
    case "copilot_cli":
        demoEvents = [
            ("sessionStart", 0),
            ("userPromptSubmitted", 3),
            ("preToolUse", 6),
            ("postToolUse", 10),
            ("errorOccurred", 18),
            ("sessionEnd", 25)
        ]
    case "windsurf":
        demoEvents = [
            ("pre_user_prompt", 0),
            ("pre_write_code", 4),
            ("post_write_code", 6),
            ("pre_run_command", 10),
            ("post_run_command", 12),
            ("pre_mcp_tool_use", 16),
            ("post_mcp_tool_use", 18),
            ("post_cascade_response", 25)
        ]
    case "codex_cli":
        demoEvents = [
            ("SessionStart", 0),
            ("UserPromptSubmit", 3),
            ("PreToolUse", 6),
            ("PostToolUse", 10),
            ("PermissionRequest", 14),
            ("Stop", 25)
        ]
    default:
        demoEvents = [("sessionStart", 0), ("sessionEnd", 10)]
    }

    let sessionId = "demo-\(UUID().uuidString.prefix(8))"
    var lastTime = 0

    for (event, delay) in demoEvents {
        let wait = delay - lastTime
        if wait > 0 { sleep(UInt32(wait)) }
        lastTime = delay

        // Windsurf uses trajectory_id; all other agents use session_id.
        let sessionKey = agent == "windsurf" ? "trajectory_id" : "session_id"
        let payload: [String: Any] = [
            sessionKey: sessionId,
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

    // Claude/VS Code cross-agent deduplication
    if shouldSkipDueToCrossAgent(declaredAgent: agent) {
        return 0
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
