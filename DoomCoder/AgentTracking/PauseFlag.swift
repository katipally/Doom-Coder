import Foundation
import OSLog

// In-memory pause flag. v1.9.1 change: was file-backed at
// ~/Library/Application Support/DoomCoder/paused — but a stray sentinel
// from a single accidental toggle would silently wedge the ENTIRE hook
// pipeline (both dc-hook AND AgentTrackingManager checked the file) and
// nothing ever reset it. Now it's pure in-memory state owned by the app,
// cleared on every launch. `dc-hook` no longer checks pause state at all.
enum PauseFlag {
    private static let logger = Logger(subsystem: "com.doomcoder", category: "pause")
    // Legacy path; only referenced by clearOnLaunch() to sweep old sentinels.
    private static var legacyFileURL: URL { AgentSupportDir.url.appendingPathComponent("paused") }

    nonisolated(unsafe) private static var _isPaused: Bool = false

    static var isPaused: Bool { _isPaused }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        _isPaused = on
        logger.info("pause flag set to \(on, privacy: .public)")
        return true
    }

    /// Called once from `applicationDidFinishLaunching` to:
    ///  - force the in-memory flag to false (no pause state persists across launches);
    ///  - delete any stale file-backed sentinel left by older builds.
    static func clearOnLaunch() {
        _isPaused = false
        let fm = FileManager.default
        if fm.fileExists(atPath: legacyFileURL.path) {
            do {
                try fm.removeItem(at: legacyFileURL)
                logger.notice("swept legacy paused sentinel at \(legacyFileURL.path, privacy: .public)")
            } catch {
                logger.error("failed to sweep legacy paused sentinel: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

enum AgentSupportDir {
    static var url: URL {
        let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return (base ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("DoomCoder", isDirectory: true)
    }

    static var socketURL: URL { url.appendingPathComponent("hook.sock") }
    static var dbURL: URL     { url.appendingPathComponent("events.sqlite") }

    @discardableResult
    static func ensure() -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch { return false }
    }
}

enum AgentLogDir {
    static var url: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let u = home.appendingPathComponent("Library/Logs/DoomCoder", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func todayLogPath(prefix: String = "doomcoder") -> URL {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let p = url.appendingPathComponent("\(prefix)-\(df.string(from: Date())).log")
        cleanupOldLogs()
        return p
    }

    private static func cleanupOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for f in files {
            if let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               mod < cutoff {
                try? fm.removeItem(at: f)
            }
        }
    }
}
