import Foundation

// Touch-file at ~/Library/Application Support/DoomCoder/paused that the helper
// binary checks to short-circuit all hook events.
enum PauseFlag {
    static var url: URL { AgentSupportDir.url.appendingPathComponent("paused") }
    static var isPaused: Bool { FileManager.default.fileExists(atPath: url.path) }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        AgentSupportDir.ensure()
        if on {
            return FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        } else {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            return true
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
        let sorted = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]))?.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        } ?? []
        var total: Int64 = 0
        for f in sorted {
            let size = (try? fm.attributesOfItem(atPath: f.path)[.size] as? Int64) ?? 0
            total += size
            if total > 10 * 1024 * 1024 {
                try? fm.removeItem(at: f)
            }
        }
    }
}
