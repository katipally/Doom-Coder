import Foundation

// MARK: - HookRoundTripTest
//
// Real end-to-end verification for the hook pipeline. Runs
// `~/.doomcoder/hook.sh <agent-id> <event>` as a subprocess with a unique
// nonce in the DC_TEST_NONCE env var; waits for that nonce to re-appear on
// our Unix socket; reports success in ms or a specific failure reason.
//
// This is the ground truth that replaces the staged `injectTest` fake. If
// the round trip succeeds, the hook runtime is wired correctly end-to-end:
//   hook.sh → nc/python → dc.sock → SocketServer → AgentStatusManager.
//
// Typical runtime is 10–40 ms on a healthy system. We give a generous
// 5-second budget before declaring failure, since `python3` fallback can
// take ~200ms to start on cold boot.

@MainActor
enum HookRoundTripTest {

    enum Failure: Error, LocalizedError {
        case hookScriptMissing(String)
        case spawnFailed(String)
        case timeout
        case socketNotRunning

        var errorDescription: String? {
            switch self {
            case .hookScriptMissing(let p):
                return "Hook script not found at \(p). DoomCoder will redeploy it on next launch — try restarting the app."
            case .spawnFailed(let msg):
                return "Couldn't run hook.sh: \(msg)"
            case .timeout:
                return "Hook ran but no event reached DoomCoder within 5 s. Check that nothing is blocking ~/.doomcoder/dc.sock."
            case .socketNotRunning:
                return "DoomCoder's socket server isn't running. Restart DoomCoder to fix."
            }
        }
    }

    struct Success {
        let millis: Int
        let event: AgentEvent
    }

    // Runs the round-trip test and returns a Result. Caller is expected to
    // display a green ✓ with `millis` on success, or a red ✗ with the error
    // description on failure.
    static func run(
        agent: HookInstaller.Agent,
        event: String = "SessionStart",
        timeout: TimeInterval = 5.0,
        statusManager: AgentStatusManager
    ) async -> Result<Success, Failure> {

        let scriptURL = HookRuntime.hookScriptURL
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            return .failure(.hookScriptMissing(scriptURL.path))
        }

        let nonce = "rt-" + UUID().uuidString
        let start = Date.now

        // Kick off subprocess. We pipe an empty-object JSON into stdin so
        // hook.sh's dd doesn't hang waiting for bytes.
        do {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = [scriptURL.path, agent.rawValue, event]
            proc.environment = (ProcessInfo.processInfo.environment).merging([
                "DC_TEST_NONCE": nonce
            ]) { _, new in new }
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            proc.standardInput = stdin
            proc.standardOutput = stdout
            proc.standardError = stderr
            try proc.run()
            try? stdin.fileHandleForWriting.write(contentsOf: Data("{}".utf8))
            try? stdin.fileHandleForWriting.close()
        } catch {
            return .failure(.spawnFailed(error.localizedDescription))
        }

        // Await the nonce echoing back on the socket.
        guard let ev = await statusManager.awaitRoundTrip(nonce: nonce, timeout: timeout) else {
            return .failure(.timeout)
        }
        let ms = Int((Date.now.timeIntervalSince(start)) * 1000)
        // v1.5: persist the success flag so the agent is recognised as
        // "configured" in the menubar Track submenu without needing to re-run.
        statusManager.markRoundTripSuccess(agentId: agent.rawValue)
        return .success(Success(millis: ms, event: ev))
    }
}
