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
    var childProcessCount: Int = 0    // live child processes spawned by this PID
    var networkIsWorking: Bool = false // from proc_pidinfo network bytes delta (CLI)
    var fseventsIsWorking: Bool = false// from FSEvents workspaceStorage burst (GUI)

    enum Kind: String { case gui, cli }

    // Aggregated "working" signal — any one of three independent indicators.
    var isWorking: Bool {
        guard isRunning else { return false }
        switch kind {
        case .cli: return childProcessCount > 0 || networkIsWorking
        case .gui: return fseventsIsWorking || (cpuPercent ?? 0) > 2.0
        }
    }
}

// MARK: - AppDetector

// Orchestrates AI app detection on this device using three complementary techniques:
//   1. DynamicAppDiscovery — scans PATH dirs and /Applications at startup; no hardcoded output list.
//   2. NSWorkspace notifications — instant, zero-poll GUI lifecycle events (launch/quit).
//   3. sysctl KERN_PROC_UID — efficient user-process table scan every 10s for CLI detection.
//
// "Working" state comes from WorkingStateDetector (FSEvents + network bytes) plus child count.
@Observable
@MainActor
final class AppDetector {

    private(set) var detectedApps: [TrackedApp] = []

    // MARK: - Owned Components

    private let workingStateDetector = WorkingStateDetector()

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
            self.workingStateDetector.onActivityDetected = { [weak self] in
                self?.updateWorkingStates()
            }
        }
    }

    deinit {
        _pollTimer?.invalidate()
        for obs in _workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    // MARK: - Scan Installed (Dynamic Discovery)

    // Rebuilds detectedApps by scanning the filesystem. Runs synchronously on the main thread.
    // Called once at startup and when the user presses "Scan" in the Active Apps window.
    private func scanInstalled() {
        let discovered = DynamicAppDiscovery.scan()
        var apps: [TrackedApp] = []
        for tool in discovered {
            apps.append(TrackedApp(
                id: tool.id,
                displayName: tool.displayName,
                kind: tool.kind == .gui ? .gui : .cli,
                isInstalled: true,
                isRunning: false
            ))
        }
        detectedApps = apps
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
                detectedApps[i].fseventsIsWorking = false
            }
        }
    }

    private func updateRunningCLI() {
        let allProcs = getAllUserProcesses()

        var byName: [String: ProcInfo] = [:]
        for p in allProcs { if byName[p.name] == nil { byName[p.name] = p } }

        // Count direct children per PID — proxy for "agent has spawned shell tasks"
        var childCounts: [pid_t: Int] = [:]
        for p in allProcs { childCounts[p.ppid, default: 0] += 1 }

        var runningCLIPids: [pid_t] = []
        for i in detectedApps.indices where detectedApps[i].kind == .cli {
            let name = detectedApps[i].id
            if let info = byName[name] {
                detectedApps[i].isRunning = true
                detectedApps[i].pid = info.pid
                detectedApps[i].childProcessCount = childCounts[info.pid] ?? 0
                runningCLIPids.append(info.pid)
            } else {
                detectedApps[i].isRunning = false
                detectedApps[i].pid = nil
                detectedApps[i].cpuPercent = nil
                detectedApps[i].childProcessCount = 0
                detectedApps[i].networkIsWorking = false
            }
        }

        // Tell WorkingStateDetector which CLI PIDs to monitor for network bytes
        workingStateDetector.monitoredCLIPids = runningCLIPids
    }

    // Applies latest FSEvents and network-bytes signals from WorkingStateDetector to detectedApps.
    // Called by WorkingStateDetector.onActivityDetected (every 2s network poll, and on FSEvents).
    private func updateWorkingStates() {
        for i in detectedApps.indices {
            let app = detectedApps[i]
            guard app.isRunning else { continue }

            switch app.kind {
            case .gui:
                detectedApps[i].fseventsIsWorking = workingStateDetector.isWorkingViaFSEvents(appID: app.id)
            case .cli:
                if let pid = app.pid {
                    detectedApps[i].networkIsWorking = workingStateDetector.isWorkingViaNetwork(pid: pid)
                }
            }
        }
        // Record transitions for completion notifications
        for app in detectedApps where app.isRunning {
            NotificationManager.shared.record(app: app)
        }
    }

    // MARK: - sysctl Process Table

    private struct ProcInfo {
        let name: String
        let pid:  pid_t
        let ppid: pid_t
    }

    // Returns all processes owned by the current user in a single sysctl call.
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
            let kp = procs[i]
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

    // MARK: - CPU Sampling (async, non-blocking via ps)

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
                }
            }
            // Record after CPU update
            for app in detectedApps where app.isRunning {
                NotificationManager.shared.record(app: app)
            }
        }
    }

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

    // MARK: - Polling (CLI detection + CPU every 10s)

    private func startPolling() {
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateRunningCLI()
                self?.updateRunningGUI()
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

    // MARK: - Public Refresh (called by "Scan" button in Active Apps window)

    func refresh() {
        scanInstalled()
        updateRunningGUI()
        updateRunningCLI()
        sampleCPU()
    }
}
