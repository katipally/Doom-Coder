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
    var childProcessCount: Int = 0  // live child processes spawned by this process

    enum Kind: String { case gui, cli }

    // CLI agents are "working" when they have spawned child processes (shell cmds, git, compilers…)
    // GUI apps are "working" when CPU is meaningfully elevated above idle.
    var isWorking: Bool {
        guard isRunning else { return false }
        switch kind {
        case .cli: return childProcessCount > 0
        case .gui: return (cpuPercent ?? 0) > 2.0
        }
    }
}

// MARK: - AppDetector

// Scans for installed AI coding tools (GUI apps and CLI binaries), tracks which are running,
// and samples CPU usage every 10 seconds for task-completion detection.
//
// GUI apps: detected via NSWorkspace notifications (zero polling for lifecycle events).
// CLI tools: detected via sysctl(KERN_PROC_UID) filtered to the current user every 10 seconds.
@Observable
@MainActor
final class AppDetector {

    private(set) var detectedApps: [TrackedApp] = []

    // MARK: - Known App Catalog

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
        .init(bundleID: "io.zed.Zed-Preview",           displayName: "Zed Preview"),
        .init(bundleID: "com.apple.dt.Xcode",           displayName: "Xcode"),
        .init(bundleID: "com.googlecode.iterm2",         displayName: "iTerm2"),
        .init(bundleID: "dev.warp.Warp-Stable",          displayName: "Warp"),
        .init(bundleID: "com.mitchellh.ghostty",         displayName: "Ghostty"),
        .init(bundleID: "com.apple.Terminal",            displayName: "Terminal"),
        .init(bundleID: "org.alacritty",                 displayName: "Alacritty"),
        .init(bundleID: "com.jetbrains.intellij",        displayName: "IntelliJ IDEA"),
        .init(bundleID: "com.jetbrains.pycharm",         displayName: "PyCharm"),
        .init(bundleID: "com.jetbrains.webstorm",        displayName: "WebStorm"),
        .init(bundleID: "com.jetbrains.rider",           displayName: "Rider"),
    ]

    private let knownCLITools: [KnownCLITool] = [
        .init(binaryName: "claude",    displayName: "Claude Code"),
        .init(binaryName: "codex",     displayName: "OpenAI Codex"),
        .init(binaryName: "aider",     displayName: "Aider"),
        .init(binaryName: "gemini",    displayName: "Gemini CLI"),
        .init(binaryName: "copilot",   displayName: "GitHub Copilot CLI"),
        .init(binaryName: "goose",     displayName: "Goose"),
        .init(binaryName: "amp",       displayName: "Amp"),
        .init(binaryName: "cody",      displayName: "Sourcegraph Cody"),
        .init(binaryName: "continue",  displayName: "Continue"),
        .init(binaryName: "windsurf",  displayName: "Windsurf CLI"),
        .init(binaryName: "cursor",    displayName: "Cursor CLI"),
    ]

    @ObservationIgnored nonisolated(unsafe) private var _pollTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var _workspaceObservers: [NSObjectProtocol] = []

    // MARK: - Init / Deinit

    init() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scanInstalled()
            self.updateRunningGUI()
            self.updateRunningCLI()
            self.startPolling()
            self.subscribeToWorkspaceNotifications()
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

    // Builds the detectedApps list from apps confirmed installed on this device.
    private func scanInstalled() {
        var apps: [TrackedApp] = []
        var seenDisplayNames = Set<String>()

        // --- GUI Apps ---
        // Fast path: NSWorkspace Launch Services lookup by bundle ID
        for known in knownGUIApps {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: known.bundleID) != nil else { continue }
            guard seenDisplayNames.insert(known.displayName).inserted else { continue }
            apps.append(TrackedApp(id: known.bundleID, displayName: known.displayName,
                                   kind: .gui, isInstalled: true, isRunning: false))
        }

        // Fallback: scan /Applications and ~/Applications for bundle IDs not found above
        let appDirs = ["/Applications",
                       (("~/Applications") as NSString).expandingTildeInPath]
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
            guard seenDisplayNames.insert(known.displayName).inserted else { continue }
            apps.append(TrackedApp(id: known.bundleID, displayName: known.displayName,
                                   kind: .gui, isInstalled: true, isRunning: false))
        }

        // --- CLI Tools ---
        let searchPaths = buildSearchPaths()
        let fm = FileManager.default
        for tool in knownCLITools {
            let isInstalled = searchPaths.contains { fm.fileExists(atPath: "\($0)/\(tool.binaryName)") }
            guard isInstalled else { continue }
            apps.append(TrackedApp(id: tool.binaryName, displayName: tool.displayName,
                                   kind: .cli, isInstalled: true, isRunning: false))
        }

        detectedApps = apps
    }

    // Builds binary search paths dynamically:
    // 1. System paths from /etc/paths and /etc/paths.d/ (set by macOS and installers like Homebrew)
    // 2. Common package manager locations as fallback
    private func buildSearchPaths() -> [String] {
        var paths: [String] = []

        if let content = try? String(contentsOfFile: "/etc/paths", encoding: .utf8) {
            paths += content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: "/etc/paths.d") {
            for entry in entries.sorted() {
                if let content = try? String(contentsOfFile: "/etc/paths.d/\(entry)", encoding: .utf8) {
                    paths += content.components(separatedBy: .newlines).filter { !$0.isEmpty }
                }
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-packages/bin",
            "\(home)/.yarn/bin",
        ]

        // Deduplicate while preserving order
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    // MARK: - Running State

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
        let allProcs = getAllUserProcesses()

        // name → first matching ProcInfo
        var byName: [String: ProcInfo] = [:]
        for p in allProcs { if byName[p.name] == nil { byName[p.name] = p } }

        // ppid → direct child count: detects when an agent has spawned shell commands, git, etc.
        var childCounts: [pid_t: Int] = [:]
        for p in allProcs { childCounts[p.ppid, default: 0] += 1 }

        for i in detectedApps.indices where detectedApps[i].kind == .cli {
            let name = detectedApps[i].id
            if let info = byName[name] {
                detectedApps[i].isRunning         = true
                detectedApps[i].pid               = info.pid
                detectedApps[i].childProcessCount = childCounts[info.pid] ?? 0
            } else {
                detectedApps[i].isRunning         = false
                detectedApps[i].pid               = nil
                detectedApps[i].cpuPercent        = nil
                detectedApps[i].childProcessCount = 0
            }
        }
    }

    // MARK: - sysctl Process Table (CLI detection)

    private struct ProcInfo {
        let name: String
        let pid:  pid_t
        let ppid: pid_t
    }

    // Returns all processes owned by the current user in one sysctl call.
    // KERN_PROC_UID filters by UID, more efficient than KERN_PROC_ALL.
    private func getAllUserProcesses() -> [ProcInfo] {
        let uid = Int32(getuid())
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, uid]
        var size = 0
        sysctl(&mib, 4, nil, &size, nil, 0)

        let count = size / MemoryLayout<kinfo_proc>.stride
        guard count > 0 else { return [] }

        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        var actualSize = size
        sysctl(&mib, 4, &procs, &actualSize, nil, 0)

        let actualCount = actualSize / MemoryLayout<kinfo_proc>.stride
        var result: [ProcInfo] = []
        result.reserveCapacity(actualCount)
        for i in 0..<actualCount {
            let kp   = procs[i]
            let pid  = kp.kp_proc.p_pid
            let ppid = kp.kp_eproc.e_ppid
            guard pid > 0 else { continue }
            let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { bytes -> String in
                guard let base = bytes.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            guard !name.isEmpty else { continue }
            result.append(ProcInfo(name: name, pid: pid, ppid: ppid))
        }
        return result
    }

    // MARK: - CPU Sampling (async, non-blocking)

    private func sampleCPU() {
        let toSample = detectedApps.filter { $0.isRunning }.compactMap { app -> (id: String, pid: pid_t)? in
            guard let pid = app.pid else { return nil }
            return (app.id, pid)
        }
        guard !toSample.isEmpty else { return }

        Task {
            let results: [(String, Double)] = await withTaskGroup(of: (String, Double).self) { group in
                for item in toSample {
                    let (id, pid) = (item.id, item.pid)
                    group.addTask { (id, await AppDetector.measureCPU(pid: pid)) }
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

    // Measures CPU% for a PID using ps. Runs on the cooperative thread pool via terminationHandler.
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

    // MARK: - Polling (CLI + CPU every 10s)

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

    // MARK: - NSWorkspace Notifications (instant GUI lifecycle events)

    private func subscribeToWorkspaceNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        let launchObs = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunningGUI() }
        }
        let quitObs = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunningGUI() }
        }
        _workspaceObservers = [launchObs, quitObs]
    }

    // MARK: - Public Refresh (e.g., Scan button in Active Apps window)

    func refresh() {
        scanInstalled()
        updateRunningGUI()
        updateRunningCLI()
    }
}
