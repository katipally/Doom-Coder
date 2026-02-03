import Darwin
import Foundation

/// Process-liveness check used to suppress phantom "done" notifications
/// when the agent process has already exited (user pressed Cmd+Q before
/// the final Stop/sessionEnd hook arrived).
enum PIDLiveness {
    /// Returns true when a process with `pid` currently exists.
    /// `kill(pid, 0)` returns 0 if the process exists and we can signal it.
    /// EPERM means the process exists but is owned by a different uid.
    /// ESRCH means no such process.
    static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let rc = kill(pid, 0)
        if rc == 0 { return true }
        return errno == EPERM
    }
}
