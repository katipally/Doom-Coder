import Foundation
import os

// MARK: - Log
//
// Thin wrapper over os.Logger giving every hop in the event pipeline a
// stable category tag. Lets us grep Console.app (subsystem "DoomCoder")
// for "[bridge-rx]" or "[ntfy-post]" when tracking down silent drops.
//
// Why not just `print`? os.Logger respects log levels, stays cheap in
// release builds, and is visible in Console.app without a debugger —
// which is the whole point: the user can open Console, filter by
// `DoomCoder`, and see the entire LLM→phone pipeline in real time.
enum Log {
    private static let subsystem = "com.doomcoder"

    // Hop tags match the plumbing audit doc:
    //   [bridge-rx]   — raw line read off the Unix domain socket (pre-parse)
    //   [ingest]      — AgentStatusManager.ingest entrypoint
    //   [gate]        — watch-target / isWatched decision per event
    //   [deliver]     — handoff to iPhoneRelay.fire
    //   [ntfy-post]   — HTTPS POST to ntfy.sh (with status code on return)
    //   [setup]       — install/uninstall + rules/MCP config writes
    //   [doctor]      — end-to-end doctor runs
    static let bridgeRx = Logger(subsystem: subsystem, category: "bridge-rx")
    static let ingest   = Logger(subsystem: subsystem, category: "ingest")
    static let gate     = Logger(subsystem: subsystem, category: "gate")
    static let deliver  = Logger(subsystem: subsystem, category: "deliver")
    static let ntfyPost = Logger(subsystem: subsystem, category: "ntfy-post")
    static let setup    = Logger(subsystem: subsystem, category: "setup")
    static let doctor   = Logger(subsystem: subsystem, category: "doctor")
}
