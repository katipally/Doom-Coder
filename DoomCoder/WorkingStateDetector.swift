import Foundation
import CoreServices
import Darwin

// Detects whether tracked apps are actively working using two native macOS signals:
//
// 1. FSEvents (IDE apps — Cursor, VS Code, Windsurf, Zed):
//    Watches workspaceStorage directories for rapid SQLite write bursts.
//    Cursor/VS Code write generation state to state.vscdb during AI responses.
//    Zero CPU overhead — kernel-level file system event notification.
//    Latency: 1.5s event coalescing.
//
// 2. Network receive bytes (CLI agents — Claude Code, Copilot CLI, etc.):
//    Uses proc_pidinfo + PROC_PIDFDSOCKETINFO to read per-socket receive buffer
//    bytes for each tracked CLI PID. Delta > 100 bytes in 2s = streaming tokens.
//    No root required for same-user processes.
@MainActor
final class WorkingStateDetector {

    // MARK: - FSEvents State

    // Maps "app category key" → last time a file-change burst was observed
    private var fseventsBursts: [String: Date] = [:]

    // FSEvents category key → bundle IDs that belong to that app family
    private let categoryBundles: [String: [String]] = [
        "cursor":   ["com.todesktop.230313mzl4w4u92", "com.cursor.cursor"],
        "vscode":   ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
        "windsurf": ["com.exafunction.windsurf"],
        "zed":      ["dev.zed.Zed", "io.zed.Zed-Preview"],
    ]

    // Dirs to watch (relative to ~/Library/Application Support/) → app category key
    private let fsWatchDirs: [(pathComponent: String, appKey: String)] = [
        ("Cursor/User/workspaceStorage",   "cursor"),
        ("Code/User/workspaceStorage",     "vscode"),
        ("Windsurf/User/workspaceStorage", "windsurf"),
    ]

    // MARK: - Network Bytes State

    // CLI PID → last measured receive buffer total (used for delta detection)
    private var lastNetworkBytes: [pid_t: UInt64] = [:]

    // CLI PID → last time meaningful network activity was observed
    private var lastNetworkActivity: [pid_t: Date] = [:]

    // PIDs to monitor — updated by AppDetector when running CLI apps change
    var monitoredCLIPids: [pid_t] = []

    // MARK: - Callbacks

    // Called after each network poll cycle and after FSEvents activity.
    // AppDetector sets this to trigger a working-state refresh.
    var onActivityDetected: (() -> Void)?

    // MARK: - Private Timers and Streams

    @ObservationIgnored nonisolated(unsafe) private var _fseventStreams: [FSEventStreamRef] = []
    @ObservationIgnored nonisolated(unsafe) private var _networkTimer: Timer?

    // MARK: - Init / Deinit

    init() {
        setupFSEvents()
        startNetworkTimer()
    }

    deinit {
        for stream in _fseventStreams {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        _networkTimer?.invalidate()
    }

    // MARK: - Public API

    // Returns true if the given GUI app bundle ID saw FSEvents activity in the last 3 seconds.
    func isWorkingViaFSEvents(appID: String) -> Bool {
        for (catKey, bundles) in categoryBundles {
            if bundles.contains(appID) {
                if let last = fseventsBursts[catKey] {
                    return Date.now.timeIntervalSince(last) < 3.0
                }
            }
        }
        return false
    }

    // Returns true if the given CLI PID received network data in the last 4 seconds.
    func isWorkingViaNetwork(pid: pid_t) -> Bool {
        guard let last = lastNetworkActivity[pid] else { return false }
        return Date.now.timeIntervalSince(last) < 4.0
    }

    // Processes an FSEvents path event (called from C callback, dispatched to main actor).
    nonisolated func handleFSEvent(path: String) {
        Task { @MainActor [weak self] in
            self?.processEvent(path: path)
        }
    }

    // MARK: - FSEvents Setup

    private func setupFSEvents() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appSupport = "\(home)/Library/Application Support"

        for watch in fsWatchDirs {
            let fullPath = "\(appSupport)/\(watch.pathComponent)"
            attachFSStream(path: fullPath, appKey: watch.appKey)
        }

        // Zed uses ~/.config/zed
        let zedPath = "\(home)/.config/zed"
        attachFSStream(path: zedPath, appKey: "zed")
    }

    private func attachFSStream(path: String, appKey: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes) | UInt32(kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            workingStateDetectorFSCallback,
            &ctx,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.5,    // 1.5s coalescing latency
            FSEventStreamCreateFlags(flags)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        _fseventStreams.append(stream)
    }

    private func processEvent(path: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appSupport = "\(home)/Library/Application Support"

        for watch in fsWatchDirs {
            let watchPath = "\(appSupport)/\(watch.pathComponent)"
            if path.hasPrefix(watchPath) {
                fseventsBursts[watch.appKey] = Date.now
                onActivityDetected?()
                return
            }
        }

        let zedPath = "\(home)/.config/zed"
        if path.hasPrefix(zedPath) {
            fseventsBursts["zed"] = Date.now
            onActivityDetected?()
        }
    }

    // MARK: - Network Bytes Monitoring

    private func startNetworkTimer() {
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollNetworkBytes() }
        }
        RunLoop.main.add(t, forMode: .common)
        _networkTimer = t
    }

    private func pollNetworkBytes() {
        guard !monitoredCLIPids.isEmpty else { return }

        var didDetect = false
        for pid in monitoredCLIPids {
            let bytes = networkReceiveBytes(pid: pid)
            let prev = lastNetworkBytes[pid] ?? 0

            // Working if: buffer has data NOW, OR buffer changed since last poll
            if bytes > 100 || (bytes != prev && bytes > 0) {
                lastNetworkActivity[pid] = Date.now
                didDetect = true
            }
            lastNetworkBytes[pid] = bytes
        }

        // Purge entries for PIDs no longer monitored
        let active = Set(monitoredCLIPids)
        for pid in lastNetworkBytes.keys where !active.contains(pid) {
            lastNetworkBytes.removeValue(forKey: pid)
            lastNetworkActivity.removeValue(forKey: pid)
        }

        if didDetect { onActivityDetected?() }
    }

    // Returns total bytes currently in receive buffers for all TCP sockets of `pid`.
    // Uses proc_pidinfo (libproc) — no root required for same-user processes.
    private func networkReceiveBytes(pid: pid_t) -> UInt64 {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return 0 }

        let count = Int(bufSize) / MemoryLayout<proc_fdinfo>.stride
        guard count > 0 else { return 0 }

        var fdBuf = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let filled = fdBuf.withUnsafeMutableBytes { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, ptr.baseAddress, bufSize)
        }
        guard filled > 0 else { return 0 }

        let actualCount = Int(filled) / MemoryLayout<proc_fdinfo>.stride
        var totalBytes: UInt64 = 0

        for i in 0..<actualCount {
            guard fdBuf[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }

            var sockInfo = socket_fdinfo()
            let sockFilled = withUnsafeMutablePointer(to: &sockInfo) { ptr in
                proc_pidfdinfo(pid, fdBuf[i].proc_fd, PROC_PIDFDSOCKETINFO,
                               ptr, Int32(MemoryLayout<socket_fdinfo>.size))
            }
            guard sockFilled > 0 else { continue }

            // Only count TCP sockets (not UDP, Unix domain sockets, etc.)
            guard sockInfo.psi.soi_protocol == Int32(IPPROTO_TCP) else { continue }

            totalBytes += UInt64(sockInfo.psi.soi_rcv.sbi_cc)
        }

        return totalBytes
    }
}

// MARK: - FSEvents C Callback (file scope — no Swift captures allowed)

private func workingStateDetectorFSCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let detector = Unmanaged<WorkingStateDetector>.fromOpaque(info).takeUnretainedValue()

    let pathsArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
    for i in 0..<numEvents {
        if let path = pathsArray[i] as? String {
            detector.handleFSEvent(path: path)
        }
    }
}
