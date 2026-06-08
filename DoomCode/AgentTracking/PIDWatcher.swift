import Foundation

// Watches a set of PIDs using DispatchSource (kqueue EVFILT_PROC + NOTE_EXIT under the hood).
// When a watched PID exits without a terminal hook event, the session is
// finalized as completed (so the badge transitions completed -> idle via
// the auto-revert path, and no "disconnected" state is shown).
//
// Requirements:
// - App must NOT be sandboxed (DoomCode.entitlements: app-sandbox = false) — satisfied.
// - Sources must be held strongly or they auto-cancel before firing.
// - All methods must be called on the main actor.
@MainActor
final class PIDWatcher {
    static let shared = PIDWatcher()

    private var sources: [pid_t: DispatchSourceProcess] = [:]
    private var pidToSessionKey: [pid_t: String] = [:]

    private init() {}

    // Start watching `pid`. When the process exits, finalizes the session
    // via AgentTrackingManager.finalizeOnPIDExit.
    // Safe to call repeatedly — duplicate watch for the same pid+key is a no-op.
    // PID recycle: if the same PID is now associated with a different sessionKey,
    // the old watcher is cancelled and replaced.
    func watch(pid: pid_t, sessionKey: String) {
        guard pid > 0 else { return }

        // Handle PID recycle: same PID, different session key.
        if let existingKey = pidToSessionKey[pid], existingKey != sessionKey {
            sources[pid]?.cancel()
            sources.removeValue(forKey: pid)
            pidToSessionKey.removeValue(forKey: pid)
        }

        // Already watching this exact pid+key pair.
        guard sources[pid] == nil else { return }

        let src = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            src.cancel()
            self.sources.removeValue(forKey: pid)
            if let key = self.pidToSessionKey.removeValue(forKey: pid) {
                AgentTrackingManager.shared.finalizeOnPIDExit(sessionKey: key)
            }
        }
        src.resume()  // MUST call resume() or the source never fires.
        sources[pid] = src
        pidToSessionKey[pid] = sessionKey
    }

    // Cancel the watcher for `pid` (e.g. when a session ends normally).
    func cancel(pid: pid_t) {
        guard pid > 0 else { return }
        sources[pid]?.cancel()
        sources.removeValue(forKey: pid)
        pidToSessionKey.removeValue(forKey: pid)
    }
}
