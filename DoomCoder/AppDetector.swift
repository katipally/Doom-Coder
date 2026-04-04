import Foundation
import AppKit
import Darwin

// MARK: - TrackedApp

struct TrackedApp: Identifiable {
    let id: String           // bundle ID for GUI apps; binary name for CLI tools
    let displayName: String
    let kind: Kind

    var isInstalled: Bool
    var isRunning: Bool
    var pid: pid_t?
    var cpuPercent: Double?

    enum Kind: String { case gui, cli }

    var statusText: String {
        guard isRunning else { return "not running" }
        if let cpu = cpuPercent {
            return cpu < 1.0 ? "idle" : String(format: "%.0f%% CPU", cpu)
        }
        return "running"
    }
}

// MARK: - AppDetector

// Scans the user's machine for known AI coding tools (GUI apps + CLI binaries),
// tracks which ones are currently running, and samples CPU for completion detection.
// GUI apps are tracked via NSWorkspace notifications (zero polling).
// CLI tools are detected via sysctl(KERN_PROC_ALL) every 10 seconds.
@Observable
@MainActor
final class AppDetector {

    private(set) var detectedApps: [TrackedApp] = []

    // MARK: - Curated Knowledge Base

    private struct KnownGUIApp {
        let bundleID: String
        let displayName: String
    }

    private struct KnownCLITool {
        let binaryName: String
        let displayName: String
    }

    private let knownGUIApps: [KnownGUIApp] = [
        .init(bundleID: "com.todesktop.230313mzl4w4u92", displayName: "Cursor"),
        .init(bundleID: "com.cursor.cursor",             displayName: "Cursor"),
        .init(bundleID: "com.microsoft.VSCode",          displayName: "VS Code"),
        .init(bundleID: "com.microsoft.VSCodeInsiders",  displayName: "VS Code Insiders"),
        .init(bundleID: "com.exafunction.windsurf",      displayName: "Windsurf"),
        .init(bundleID: "dev.zed.Zed",                  displayName: "Zed"),
        .init(bundleID: "com.apple.dt.Xcode",           displayName: "Xcode"),
        .init(bundleID: "com.googlecode.iterm2",         displayName: "iTerm2"),
        .init(bundleID: "dev.warp.Warp-Stable",          displayName: "Warp"),
        .init(bundleID: "com.mitchellh.ghostty",         displayName: "Ghostty"),
        .init(bundleID: "com.apple.Terminal",            displayName: "Terminal"),
        .init(bundleID: "org.alacritty",                 displayName: "Alacritty"),
        .init(bundleID: "io.zed.Zed-Preview",           displayName: "Zed Preview"),
        .init(bundleID: "com.jetbrains.intellij",        displayName: "IntelliJ IDEA"),
        .init(bundleID: "com.jetbrains.pycharm",         displayName: "PyCharm"),
        .init(bundleID: "com.jetbrains.webstorm",        displayName: "WebStorm"),
    ]

    private let knownCLITools: [KnownCLITool] = [
        .init(binaryName: "claude",    displayName: "Claude Code"),
        .init(binaryName: "codex",     displayName: "Codex CLI"),
        .init(binaryName: "aider",     displayName: "Aider"),
        .init(binaryName: "cursor",    displayName: "Cursor CLI"),
        .init(binaryName: "windsurf",  displayName: "Windsurf CLI"),
        .init(binaryName: "continue",  displayName: "Continue"),
        .init(binaryName: "goose",     displayName: "Goose"),
        .init(binaryName: "amp",       displayName: "Amp"),
        .init(binaryName: "copilot",   displayName: "Copilot CLI"),
        .init(binaryName: "cody",      displayName: "Sourcegraph Cody"),
        .init(binaryName: "gemini",    displayName: "Gemini CLI"),
    ]

    // Directories to search for CLI binaries
    private let binarySearchPaths: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        (("~/.local/bin") as NSString).expandingTildeInPath,
        (("~/.bun/bin") as NSString).expandingTildeInPath,
        (("~/.cargo/bin") as NSString).expandingTildeInPath,
        (("~/.npm-packages/bin") as NSString).expandingTildeInPath,
        (("~/.npm/bin") as NSString).expandingTildeInPath,
        (("~/.yarn/bin") as NSString).expandingTildeInPath,
        (("~/.pnpm-global/5/node_modules/.bin") as NSString).expandingTildeInPath,
    ]

    @ObservationIgnored nonisolated(unsafe) private var _pollTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var _workspaceObservers: [NSObjectProtocol] = []

    // MARK: - Init / Deinit

    init() {
        // Defer all heavy work (file system scan, sysctl, notification auth) to the next
        // run-loop tick so the app launches instantly without blocking the main thread.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scanInstalled()
            self.updateRunningGUI()
            self.updateRunningCLI()
            self.startPolling()
            self.subscribeToWorkspaceNotifications()
            // Request notification authorization once, after app fully launches.
            NotificationManager.shared.setup()
        }
    }

    deinit {
        _pollTimer?.invalidate()
        for obs in _workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    // MARK: - Scan Installed Apps

    private func scanInstalled() {
        var apps: [TrackedApp] = []
        var seenDisplayNames = Set<String>()

        // --- GUI Apps ---
        // 1. Fast path: ask NSWorkspace if the bundle is registered
        for known in knownGUIApps {
            let isInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: known.bundleID) != nil
            guard isInstalled else { continue }
            // Deduplicate by display name (e.g., two Cursor bundle IDs)
            guard !seenDisplayNames.contains(known.displayName) else { continue }
            seenDisplayNames.insert(known.displayName)
            apps.append(TrackedApp(
                id: known.bundleID,
                displayName: known.displayName,
                kind: .gui,
                isInstalled: true,
                isRunning: false
            ))
        }

        // 2. Fallback: scan /Applications + ~/Applications for bundle IDs we missed
        let appDirs = [
            "/Applications",
            (("~/Applications") as NSString).expandingTildeInPath,
        ]
        var installedBundleIDs = Set<String>()
        for dir in appDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let plistPath = "\(dir)/\(entry)/Contents/Info.plist"
                if let plist = NSDictionary(contentsOfFile: plistPath),
                   let bundleID = plist["CFBundleIdentifier"] as? String {
                    installedBundleIDs.insert(bundleID)
                }
            }
        }
        for known in knownGUIApps {
            guard installedBundleIDs.contains(known.bundleID) else { continue }
            guard !seenDisplayNames.contains(known.displayName) else { continue }
            seenDisplayNames.insert(known.displayName)
            apps.append(TrackedApp(
                id: known.bundleID,
                displayName: known.displayName,
                kind: .gui,
                isInstalled: true,
                isRunning: false
            ))
        }

        // --- CLI Tools ---
        let fm = FileManager.default
        for tool in knownCLITools {
            let isInstalled = binarySearchPaths.contains { dir in
                fm.fileExists(atPath: "\(dir)/\(tool.binaryName)")
            }
            guard isInstalled else { continue }
            apps.append(TrackedApp(
                id: tool.binaryName,
                displayName: tool.displayName,
                kind: .cli,
                isInstalled: true,
                isRunning: false
            ))
        }

        detectedApps = apps
    }

    // MARK: - Update Running State

    private func updateRunningGUI() {
        let runningApps = NSWorkspace.shared.runningApplications
        for i in detectedApps.indices where detectedApps[i].kind == .gui {
            if let running = runningApps.first(where: { $0.bundleIdentifier == detectedApps[i].id }) {
                detectedApps[i].isRunning = true
                detectedApps[i].pid = running.processIdentifier
            } else {
                detectedApps[i].isRunning = false
                detectedApps[i].pid = nil
                detectedApps[i].cpuPercent = nil
            }
        }
    }

    private func updateRunningCLI() {
        let processList = allRunningProcesses()
        for i in detectedApps.indices where detectedApps[i].kind == .cli {
            let name = detectedApps[i].id  // binary name == process name for CLI tools
            if let pid = processList[name] {
                detectedApps[i].isRunning = true
                detectedApps[i].pid = pid
            } else {
                detectedApps[i].isRunning = false
                detectedApps[i].pid = nil
                detectedApps[i].cpuPercent = nil
            }
        }
    }

    // MARK: - sysctl Process Table (CLI detection)

    // Returns a dictionary of processName → pid for all processes owned by the current user.
    private func allRunningProcesses() -> [String: pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        sysctl(&mib, 4, nil, &size, nil, 0)

        let count = size / MemoryLayout<kinfo_proc>.stride
        guard count > 0 else { return [:] }

        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        var actualSize = size
        sysctl(&mib, 4, &procs, &actualSize, nil, 0)

        let actualCount = actualSize / MemoryLayout<kinfo_proc>.stride
        var result: [String: pid_t] = [:]

        for i in 0..<actualCount {
            let proc = procs[i]
            // p_comm is a 17-byte C char array (MAXCOMLEN=16 + null)
            let commName = withUnsafeBytes(of: proc.kp_proc.p_comm) { bytes -> String in
                guard let base = bytes.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            let pid = proc.kp_proc.p_pid
            if !commName.isEmpty && pid > 0 {
                result[commName] = pid
            }
        }
        return result
    }

    // MARK: - CPU Sampling (async, non-blocking)

    private func sampleCPU() {
        let toSample: [(id: String, pid: pid_t)] = detectedApps
            .filter { $0.isRunning }
            .compactMap { app in
                guard let pid = app.pid else { return nil }
                return (app.id, pid)
            }
        guard !toSample.isEmpty else { return }

        Task {
            let results: [(String, Double)] = await withTaskGroup(of: (String, Double).self) { group in
                for item in toSample {
                    let pid = item.pid
                    let id = item.id
                    group.addTask {
                        let cpu = await AppDetector.measureCPU(pid: pid)
                        return (id, cpu)
                    }
                }
                var collected: [(String, Double)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (id, cpu) in results {
                if let idx = detectedApps.firstIndex(where: { $0.id == id }) {
                    detectedApps[idx].cpuPercent = cpu
                    NotificationManager.shared.record(app: detectedApps[idx])
                }
            }
        }
    }

    // Non-isolating CPU measurement via `ps`. Runs on cooperative thread pool.
    // Uses terminationHandler to avoid blocking any thread.
    nonisolated static func measureCPU(pid: pid_t) async -> Double {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-p", "\(pid)", "-o", "%cpu="]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
                continuation.resume(returning: Double(raw) ?? 0)
            }
            guard (try? process.run()) != nil else {
                continuation.resume(returning: 0)
                return
            }
        }
    }

    // MARK: - Polling Timer (CLI + CPU, every 10s)

    private func startPolling() {
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateRunningCLI()
                self?.sampleCPU()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        _pollTimer = t
    }

    // MARK: - NSWorkspace Notifications (instant GUI app detection)

    private func subscribeToWorkspaceNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        let launchObs = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunningGUI() }
        }

        let quitObs = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunningGUI() }
        }

        _workspaceObservers = [launchObs, quitObs]
    }

    // MARK: - Refresh (called externally, e.g., when menu opens)

    func refresh() {
        scanInstalled()
        updateRunningGUI()
        updateRunningCLI()
    }
}
