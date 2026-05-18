import AppKit
import Darwin
import Foundation
import Observation

// Tracks whether each agent's app or CLI process is currently running.
// IDEs (Cursor, VSCode, Windsurf) are tracked via NSWorkspace push notifications — zero polling.
// CLIs (Claude, Codex, Copilot) are tracked via proc_listpids scan every 30 seconds.
//
// Publishes isAppRunning changes as .doomcoderProcessStateChanged notifications so
// TrackAgentsView and TrackAccordion can refresh without polling.
@Observable
@MainActor
final class AgentProcessMonitor {
    static let shared = AgentProcessMonitor()

    // True when the agent's app or CLI process is detected as running.
    var isAppRunning: [TrackedAgent: Bool] = [:]

    // Bundle IDs to check for IDE agents. Multiple IDs per agent to handle
    // distribution variants (e.g. VSCode + VSCode Insiders).
    private static let ideBundleIDs: [TrackedAgent: [String]] = [
        .cursor:   ["com.todesktop.230313mzl4w4u92", "com.cursor.app"],
        .vscode:   ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
        .windsurf: ["com.codeium.windsurf", "com.exafunction.windsurf"],
    ]

    // Exact proc_name matches for CLI agents (16-char kernel limit is fine here).
    private static let cliProcessNames: [TrackedAgent: String] = [
        .claude:     "claude",
        .codexCLI:   "codex",
        .copilotCLI: "copilot",
    ]

    private var cliScanTimer: Timer?

    private init() {
        // 1. Initial state: snapshot NSRunningApplication for IDEs.
        for (agent, ids) in Self.ideBundleIDs {
            isAppRunning[agent] = ids.contains {
                !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
            }
        }

        // 2. Initial state: proc_listpids scan for CLIs.
        for (agent, name) in Self.cliProcessNames {
            isAppRunning[agent] = !pidsForName(name).isEmpty
        }

        // 3. NSWorkspace push notifications for IDE open/close (zero-cost, no polling).
        let wsNC = NSWorkspace.shared.notificationCenter
        wsNC.addObserver(self, selector: #selector(appLaunched(_:)),
                         name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        wsNC.addObserver(self, selector: #selector(appTerminated(_:)),
                         name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // 4. 30-second timer for CLI scanning (NSWorkspace notifications don't cover plain processes).
        cliScanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scanCLIs() }
        }
    }

    deinit {
        // Timer and NotificationCenter cleanup happens on dealloc.
        // cliScanTimer is automatically invalidated when the object deallocates
        // because Timer holds a weak reference back to self via the [weak self] closure.
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - NSWorkspace notification handlers

    @objc private func appLaunched(_ notification: NSNotification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bid = app.bundleIdentifier else { return }
        for (agent, ids) in Self.ideBundleIDs where ids.contains(bid) {
            if isAppRunning[agent] != true {
                isAppRunning[agent] = true
                NotificationCenter.default.post(name: .doomcoderProcessStateChanged, object: nil)
            }
        }
    }

    @objc private func appTerminated(_ notification: NSNotification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bid = app.bundleIdentifier else { return }
        for (agent, ids) in Self.ideBundleIDs where ids.contains(bid) {
            // Recheck: another instance of the same app might still be open (e.g. two VSCode windows).
            let stillRunning = ids.contains {
                !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
            }
            if isAppRunning[agent] != stillRunning {
                isAppRunning[agent] = stillRunning
                NotificationCenter.default.post(name: .doomcoderProcessStateChanged, object: nil)
            }
        }
    }

    // MARK: - CLI scan

    private func scanCLIs() {
        var changed = false
        for (agent, name) in Self.cliProcessNames {
            let running = !pidsForName(name).isEmpty
            if isAppRunning[agent] != running {
                isAppRunning[agent] = running
                changed = true
            }
        }
        if changed {
            NotificationCenter.default.post(name: .doomcoderProcessStateChanged, object: nil)
        }
    }

    // MARK: - proc_listpids helper

    private func pidsForName(_ target: String) -> [pid_t] {
        let countBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard countBytes > 0 else { return [] }
        let capacity = Int(countBytes) / MemoryLayout<pid_t>.size + 16
        var buf = [pid_t](repeating: 0, count: capacity)
        let filledBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buf,
                                        Int32(capacity * MemoryLayout<pid_t>.size))
        guard filledBytes > 0 else { return [] }
        let n = Int(filledBytes) / MemoryLayout<pid_t>.size
        return buf.prefix(n).filter { pid in
            guard pid > 0 else { return false }
            var name = [CChar](repeating: 0, count: 17)  // MAXCOMLEN+1 = 17
            guard proc_name(pid, &name, 17) > 0 else { return false }
            return name.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return false }
                return String(decoding: UnsafeRawBufferPointer(start: base,
                    count: strnlen(base, 16)), as: UTF8.self) == target
            }
        }
    }
}
