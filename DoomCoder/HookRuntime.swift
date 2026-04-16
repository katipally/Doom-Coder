import Foundation

// MARK: - HookRuntime
//
// Deploys the `hook.sh` shell script to ~/.doomcoder/ on launch. The script is the
// actual bridge: hook handlers invoke it, it reads their stdin JSON, and pipes a
// minimal AgentEvent JSON line to ~/.doomcoder/dc.sock via `nc -U`.
//
// The script is generated in Swift rather than bundled as a resource so we avoid
// pbxproj resource wiring and guarantee the content matches exactly what the app
// version expects. The first line embeds the DoomCoder build version so we can
// auto-overwrite it whenever the app updates.

@MainActor
enum HookRuntime {

    static let scriptVersion = "1"

    // MARK: - Paths

    static var rootDirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".doomcoder", isDirectory: true)
    }

    static var hookScriptURL: URL {
        rootDirURL.appendingPathComponent("hook.sh")
    }

    static var socketPath: String {
        rootDirURL.appendingPathComponent("dc.sock").path
    }

    // MARK: - Deployment

    // True if hook.sh exists on disk at the current version.
    static var isDeployed: Bool {
        guard FileManager.default.fileExists(atPath: hookScriptURL.path) else { return false }
        guard let content = try? String(contentsOf: hookScriptURL, encoding: .utf8) else { return false }
        return content.contains("DC_HOOK_VERSION=\(scriptVersion)")
    }

    // Deploys (or overwrites) hook.sh in ~/.doomcoder/. Safe to call on every launch.
    static func deploy() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: rootDirURL.path) {
            try fm.createDirectory(at: rootDirURL, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirURL.path)

        let body = generateScript()
        try body.write(to: hookScriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptURL.path)
    }

    // MARK: - Script generation
    //
    // The shell script must:
    //   1. Exit 0 unconditionally, even if DoomCoder is off or the socket is gone —
    //      we never want to block the user's agent.
    //   2. Accept two positional args: <agent-id> <event-name>.
    //   3. Read hook JSON from stdin (Claude Code payloads can be ~2 KiB).
    //   4. Extract the most useful fields (cwd, tool_name, session_id) using plain
    //      POSIX grep/awk/sed so we don't depend on jq.
    //   5. Map hook event name → status code (s/w/i/e/d) via a small case table.
    //   6. Emit a single line of JSON to the Unix socket via `nc -U -w 1`.
    //      If `nc -U` is unavailable (unlikely on macOS), fall back to Python 3.

    private static func generateScript() -> String {
        let socket = socketPath
        return #"""
#!/bin/sh
# DoomCoder hook runner — DO NOT EDIT.
# Auto-deployed by DoomCoder.app to ~/.doomcoder/hook.sh.
# This script is overwritten on every DoomCoder launch.
# See https://github.com/katipally/Doom-Coder for details.

DC_HOOK_VERSION=\#(scriptVersion)
DC_SOCKET="\#(socket)"
DC_AGENT="${1:-unknown}"
DC_EVENT="${2:-unknown}"

# Never block the agent.
trap 'exit 0' INT TERM HUP PIPE

# Read stdin with a tiny timeout so we can't hang a hung agent.
DC_PAYLOAD=""
if [ ! -t 0 ]; then
    DC_PAYLOAD=$(dd bs=1 count=65536 2>/dev/null || true)
fi

# Extract a JSON string field using POSIX-only text tools.
# Usage: extract_field <field-name> <json>
dc_field() {
    printf '%s' "$2" \
        | tr -d '\n' \
        | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n 1
}

DC_SID=$(dc_field "session_id" "$DC_PAYLOAD")
[ -z "$DC_SID" ] && DC_SID=$(dc_field "sessionId" "$DC_PAYLOAD")
DC_CWD=$(dc_field "cwd" "$DC_PAYLOAD")
[ -z "$DC_CWD" ] && DC_CWD="$PWD"
DC_TOOL=$(dc_field "tool_name" "$DC_PAYLOAD")
[ -z "$DC_TOOL" ] && DC_TOOL=$(dc_field "tool" "$DC_PAYLOAD")

# Map hook event → single-char status code.
# Claude Code event names: SessionStart, SessionEnd, PreToolUse, PostToolUse,
# Notification, UserPromptSubmit, Stop, SubagentStop. Copilot CLI uses similar
# names passed as $2 from the extension shim.
case "$DC_EVENT" in
    SessionStart|sessionStart|session_start)                  DC_STATUS="s" ;;
    Stop|SessionEnd|sessionEnd|session_end|SubagentStop)      DC_STATUS="d" ;;
    Notification|notification|UserPromptSubmit|PermissionRequest) DC_STATUS="w" ;;
    Error|error)                                              DC_STATUS="e" ;;
    *)                                                        DC_STATUS="i" ;;
esac

DC_TS=$(date +%s)

# Escape characters that would break a JSON string.
dc_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' \
        | tr -d '\n' | tr -d '\r'
}

DC_SID_J=$(dc_escape "$DC_SID")
DC_CWD_J=$(dc_escape "$DC_CWD")
DC_TOOL_J=$(dc_escape "$DC_TOOL")
DC_EVENT_J=$(dc_escape "$DC_EVENT")

DC_LINE='{"src":"hook","agent":"'"$DC_AGENT"'","s":"'"$DC_STATUS"'","sid":"'"$DC_SID_J"'","cwd":"'"$DC_CWD_J"'","tool":"'"$DC_TOOL_J"'","event":"'"$DC_EVENT_J"'","t":'"$DC_TS"'}'

# Try nc (BSD netcat ships with macOS).
if command -v nc >/dev/null 2>&1; then
    printf '%s\n' "$DC_LINE" | nc -U -w 1 "$DC_SOCKET" >/dev/null 2>&1 &
    exit 0
fi

# Fallback to Python 3 if nc isn't available (very unlikely on macOS).
if command -v python3 >/dev/null 2>&1; then
    python3 - "$DC_SOCKET" <<PY "$DC_LINE" >/dev/null 2>&1 &
import socket, sys
path = sys.argv[1]
line = sys.stdin.read()
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(1.0)
    s.connect(path)
    s.sendall((line + "\n").encode("utf-8"))
    s.close()
except Exception:
    pass
PY
    exit 0
fi

exit 0
"""#
    }
}
