import Foundation
import SQLite3

// Lightweight wrapper around SQLite for agent event history.
// Schema: events(id, session_key, agent, event, tool, path, state, ts, payload)
// Also stores notification dispatch history for the Logs tab.
// Auto-purges rows older than configurable retention on open().
@MainActor
final class EventStore {
    static let shared = EventStore()

    // db is accessed only through insertQueue (writes) and from @MainActor (opens/reads).
    // Marking nonisolated(unsafe) lets the insertQueue closure reference it safely.
    nonisolated(unsafe) private var db: OpaquePointer?
    private let insertQueue = DispatchQueue(label: "com.doomcoder.EventStore.insert")

    static let retentionKey = "doomcoder.events.retentionDays"

    /// Retention in days: 1, 7, or 30. Default 7.
    static var retentionDays: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: retentionKey)
            return v > 0 ? v : 7
        }
        set { UserDefaults.standard.set(newValue, forKey: retentionKey) }
    }

    private init() { open() }

    // MARK: - Lifecycle

    func open() {
        AgentSupportDir.ensure()
        let path = AgentSupportDir.dbURL.path
        if db != nil { return }
        // Use SQLITE_OPEN_FULLMUTEX (serialized mode) so the single connection
        // is safe to access from the MainActor (reads during SwiftUI body) and
        // the background insertQueue concurrently. Prior default mode caused
        // memory corruption crashes in sqlite3VdbeExec during view updates.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            db = nil
            return
        }
        // Enable WAL for better concurrent read/write behavior.
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("""
            CREATE TABLE IF NOT EXISTS events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_key TEXT NOT NULL,
              agent TEXT NOT NULL,
              event TEXT NOT NULL,
              tool TEXT,
              path TEXT,
              state TEXT,
              ts REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_key, ts);
            CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
        """)
        // Schema migration: add payload column if missing
        migrate()
        // Also create notifications table
        exec("""
            CREATE TABLE IF NOT EXISTS notifications (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_key TEXT NOT NULL,
              agent TEXT NOT NULL,
              event TEXT NOT NULL,
              title TEXT NOT NULL,
              body TEXT NOT NULL,
              channel TEXT NOT NULL,
              success INTEGER NOT NULL DEFAULT 1,
              ts REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_notifications_ts ON notifications(ts);
        """)
        // Session history: one row per completed session
        exec("""
            CREATE TABLE IF NOT EXISTS session_history (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_key TEXT NOT NULL,
              agent TEXT NOT NULL,
              started_at REAL NOT NULL,
              ended_at REAL NOT NULL,
              duration_seconds REAL NOT NULL,
              outcome TEXT NOT NULL,
              tool_count INTEGER NOT NULL DEFAULT 0,
              permission_count INTEGER NOT NULL DEFAULT 0,
              subagent_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_session_history_agent ON session_history(agent, ended_at);
            CREATE INDEX IF NOT EXISTS idx_session_history_ts ON session_history(ended_at);
        """)
        purgeOld()
    }

    private func migrate() {
        // Add payload column if it doesn't exist
        if !columnExists("events", column: "payload") {
            exec("ALTER TABLE events ADD COLUMN payload TEXT;")
        }
    }

    private func columnExists(_ table: String, column: String) -> Bool {
        guard let db else { return false }
        let sql = "PRAGMA table_info(\(table));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) {
                if String(cString: name) == column { return true }
            }
        }
        return false
    }

    func close() {
        if db != nil { sqlite3_close(db); db = nil }
    }

    // MARK: - Event Writes

    nonisolated func insert(sessionKey: String, agent: String, event: String,
                            tool: String?, path: String?, state: String?, ts: TimeInterval,
                            payload: String? = nil) {
        let sql = "INSERT INTO events(session_key,agent,event,tool,path,state,ts,payload) VALUES(?,?,?,?,?,?,?,?);"
        insertQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLITE_TRANSIENT
            sqlite3_bind_text(stmt, 1, sessionKey, -1, T)
            sqlite3_bind_text(stmt, 2, agent, -1, T)
            sqlite3_bind_text(stmt, 3, event, -1, T)
            if let tool  { sqlite3_bind_text(stmt, 4, tool, -1, T) } else { sqlite3_bind_null(stmt, 4) }
            if let path  { sqlite3_bind_text(stmt, 5, path, -1, T) } else { sqlite3_bind_null(stmt, 5) }
            if let state { sqlite3_bind_text(stmt, 6, state, -1, T) } else { sqlite3_bind_null(stmt, 6) }
            sqlite3_bind_double(stmt, 7, ts)
            if let payload { sqlite3_bind_text(stmt, 8, payload, -1, T) } else { sqlite3_bind_null(stmt, 8) }
            _ = sqlite3_step(stmt)
        }
    }

    // MARK: - Notification Writes

    nonisolated func insertNotification(sessionKey: String, agent: String, event: String,
                                        title: String, body: String, channel: String,
                                        success: Bool, ts: TimeInterval) {
        let sql = "INSERT INTO notifications(session_key,agent,event,title,body,channel,success,ts) VALUES(?,?,?,?,?,?,?,?);"
        insertQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, sessionKey, -1, T)
            sqlite3_bind_text(stmt, 2, agent, -1, T)
            sqlite3_bind_text(stmt, 3, event, -1, T)
            sqlite3_bind_text(stmt, 4, title, -1, T)
            sqlite3_bind_text(stmt, 5, body, -1, T)
            sqlite3_bind_text(stmt, 6, channel, -1, T)
            sqlite3_bind_int(stmt, 7, success ? 1 : 0)
            sqlite3_bind_double(stmt, 8, ts)
            _ = sqlite3_step(stmt)
        }
    }

    // MARK: - Event Reads

    struct Row: Identifiable, Sendable {
        let id: Int64
        let sessionKey: String
        let agent: String
        let event: String
        let tool: String?
        let path: String?
        let state: String?
        let ts: TimeInterval
        let payload: String?
    }

    func recent(limit: Int = 200) -> [Row] {
        guard let db else { return [] }
        let sql = "SELECT id,session_key,agent,event,tool,path,state,ts,payload FROM events ORDER BY id DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        return readRows(stmt)
    }

    func recent(agent: String, limit: Int = 200) -> [Row] {
        guard let db else { return [] }
        let sql = "SELECT id,session_key,agent,event,tool,path,state,ts,payload FROM events WHERE agent=? ORDER BY id DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, agent, -1, T)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        return readRows(stmt)
    }

    func events(forSessionKey key: String, limit: Int = 500) -> [Row] {
        guard let db else { return [] }
        let sql = "SELECT id,session_key,agent,event,tool,path,state,ts,payload FROM events WHERE session_key=? ORDER BY ts ASC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, T)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        return readRows(stmt)
    }

    func count(agent: String? = nil) -> Int {
        guard let db else { return 0 }
        if let agent {
            let sql = "SELECT COUNT(*) FROM events WHERE agent=?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, agent, -1, T)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        } else {
            let sql = "SELECT COUNT(*) FROM events;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    func lastEvent(agent: String) -> Row? {
        guard let db else { return nil }
        let sql = "SELECT id,session_key,agent,event,tool,path,state,ts,payload FROM events WHERE agent=? ORDER BY id DESC LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, agent, -1, T)
        let rows = readRows(stmt)
        return rows.first
    }

    /// Events received from this agent in the last `seconds`.
    func recentCount(agent: String, seconds: TimeInterval = 3600) -> Int {
        guard let db else { return 0 }
        let cutoff = Date().timeIntervalSince1970 - seconds
        let sql = "SELECT COUNT(*) FROM events WHERE agent=? AND ts>=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, agent, -1, T)
        sqlite3_bind_double(stmt, 2, cutoff)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func readRows(_ stmt: OpaquePointer?) -> [Row] {
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Row(
                id: sqlite3_column_int64(stmt, 0),
                sessionKey: str(stmt, 1) ?? "",
                agent: str(stmt, 2) ?? "",
                event: str(stmt, 3) ?? "",
                tool: str(stmt, 4),
                path: str(stmt, 5),
                state: str(stmt, 6),
                ts: sqlite3_column_double(stmt, 7),
                payload: str(stmt, 8)
            ))
        }
        return rows
    }

    // MARK: - Session History Writes

    struct SessionHistoryEntry: Identifiable, Sendable {
        let id: Int64
        let sessionKey: String
        let agent: String
        let startedAt: Date
        let endedAt: Date
        let durationSeconds: TimeInterval
        let outcome: String   // "completed" | "failed" | "reverted"
        let toolCount: Int
        let permissionCount: Int
        let subagentCount: Int
    }

    nonisolated func insertSessionHistory(sessionKey: String, agent: String,
                                          startedAt: Date, endedAt: Date,
                                          outcome: String, toolCount: Int,
                                          permissionCount: Int, subagentCount: Int) {
        let duration = endedAt.timeIntervalSince(startedAt)
        let sql = """
            INSERT INTO session_history(session_key,agent,started_at,ended_at,
            duration_seconds,outcome,tool_count,permission_count,subagent_count)
            VALUES(?,?,?,?,?,?,?,?,?);
            """
        insertQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, sessionKey, -1, T)
            sqlite3_bind_text(stmt, 2, agent, -1, T)
            sqlite3_bind_double(stmt, 3, startedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 4, endedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 5, max(0, duration))
            sqlite3_bind_text(stmt, 6, outcome, -1, T)
            sqlite3_bind_int(stmt, 7, Int32(toolCount))
            sqlite3_bind_int(stmt, 8, Int32(permissionCount))
            sqlite3_bind_int(stmt, 9, Int32(subagentCount))
            _ = sqlite3_step(stmt)
            // FIFO eviction: keep at most 500 rows
            sqlite3_exec(db,
                "DELETE FROM session_history WHERE id NOT IN (SELECT id FROM session_history ORDER BY id DESC LIMIT 500);",
                nil, nil, nil)
        }
    }

    // MARK: - Session History Reads

    func recentSessionHistory(agent agentFilter: String? = nil, limit: Int = 100) -> [SessionHistoryEntry] {
        guard let db else { return [] }
        let sql = agentFilter != nil
            ? "SELECT id,session_key,agent,started_at,ended_at,duration_seconds,outcome,tool_count,permission_count,subagent_count FROM session_history WHERE agent=? ORDER BY id DESC LIMIT \(limit);"
            : "SELECT id,session_key,agent,started_at,ended_at,duration_seconds,outcome,tool_count,permission_count,subagent_count FROM session_history ORDER BY id DESC LIMIT \(limit);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let af = agentFilter {
            let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, af, -1, T)
        }
        var entries: [SessionHistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(SessionHistoryEntry(
                id: sqlite3_column_int64(stmt, 0),
                sessionKey: str(stmt, 1) ?? "",
                agent: str(stmt, 2) ?? "",
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                endedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                durationSeconds: sqlite3_column_double(stmt, 5),
                outcome: str(stmt, 6) ?? "completed",
                toolCount: Int(sqlite3_column_int(stmt, 7)),
                permissionCount: Int(sqlite3_column_int(stmt, 8)),
                subagentCount: Int(sqlite3_column_int(stmt, 9))
            ))
        }
        return entries
    }

    // MARK: - Reconstructed sessions (derived from raw events — never lossy)

    /// One row per distinct `session_key` in the `events` table, aggregated on
    /// the fly. Unlike `session_history` (which is only written when a session
    /// reaches a terminal event), this surfaces EVERY session that produced at
    /// least one event — including ones that never ended cleanly (IDE quit
    /// directly, app restarted mid-session, crash/sleep). The Activity view uses
    /// this as its primary source so abandoned sessions are never silently
    /// dropped; `session_history` and live in-memory state only enrich it.
    struct ReconstructedSession: Identifiable, Sendable {
        let sessionKey: String
        let agent: String
        let startedAt: Date
        let endedAt: Date
        let eventCount: Int
        let toolCount: Int
        let permissionCount: Int
        let hasEnd: Bool       // a sessionEnd event was recorded
        let hasError: Bool     // a toolError/error event was recorded
        var id: String { sessionKey }
    }

    func reconstructedSessions(agent agentFilter: String? = nil, limit: Int = 200) -> [ReconstructedSession] {
        guard let db else { return [] }
        let base = """
            SELECT session_key, agent, MIN(ts) AS started, MAX(ts) AS ended, COUNT(*) AS cnt,
                   MAX(CASE WHEN state = 'sessionEnd' THEN 1 ELSE 0 END) AS has_end,
                   MAX(CASE WHEN state IN ('toolError','error') THEN 1 ELSE 0 END) AS has_error,
                   SUM(CASE WHEN state = 'toolStart' THEN 1 ELSE 0 END) AS tool_count,
                   SUM(CASE WHEN state = 'permissionNeeded' THEN 1 ELSE 0 END) AS perm_count
            FROM events
            """
        let sql = agentFilter != nil
            ? base + " WHERE agent=? GROUP BY session_key ORDER BY ended DESC LIMIT \(limit);"
            : base + " GROUP BY session_key ORDER BY ended DESC LIMIT \(limit);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let af = agentFilter {
            let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, af, -1, T)
        }
        var out: [ReconstructedSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(ReconstructedSession(
                sessionKey: str(stmt, 0) ?? "",
                agent: str(stmt, 1) ?? "",
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                endedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                eventCount: Int(sqlite3_column_int(stmt, 4)),
                toolCount: Int(sqlite3_column_int(stmt, 7)),
                permissionCount: Int(sqlite3_column_int(stmt, 8)),
                hasEnd: sqlite3_column_int(stmt, 5) != 0,
                hasError: sqlite3_column_int(stmt, 6) != 0
            ))
        }
        return out
    }

    // MARK: - Notification Reads

    struct NotificationRow: Identifiable, Sendable {
        let id: Int64
        let sessionKey: String
        let agent: String
        let event: String
        let title: String
        let body: String
        let channel: String
        let success: Bool
        let ts: TimeInterval
    }

    func recentNotifications(limit: Int = 200) -> [NotificationRow] {
        guard let db else { return [] }
        let sql = "SELECT id,session_key,agent,event,title,body,channel,success,ts FROM notifications ORDER BY id DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        return readNotificationRows(stmt)
    }

    /// Agent-filtered notification history. Mirrors `recentNotifications(limit:)`
    /// but scoped to a single agent key (e.g. `TrackedAgent.claude.rawValue`).
    func recentNotifications(agent agentFilter: String, limit: Int = 200) -> [NotificationRow] {
        guard let db else { return [] }
        let sql = "SELECT id,session_key,agent,event,title,body,channel,success,ts FROM notifications WHERE agent=? ORDER BY id DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, agentFilter, -1, T)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        return readNotificationRows(stmt)
    }

    private func readNotificationRows(_ stmt: OpaquePointer?) -> [NotificationRow] {
        var rows: [NotificationRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(NotificationRow(
                id: sqlite3_column_int64(stmt, 0),
                sessionKey: str(stmt, 1) ?? "",
                agent: str(stmt, 2) ?? "",
                event: str(stmt, 3) ?? "",
                title: str(stmt, 4) ?? "",
                body: str(stmt, 5) ?? "",
                channel: str(stmt, 6) ?? "",
                success: sqlite3_column_int(stmt, 7) != 0,
                ts: sqlite3_column_double(stmt, 8)
            ))
        }
        return rows
    }

    // MARK: - Clear

    func clearAll() {
        exec("DELETE FROM events;")
        exec("DELETE FROM notifications;")
        exec("DELETE FROM session_history;")
    }

    func clearAgent(_ agent: String) {
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for sql in ["DELETE FROM events WHERE agent=?;", "DELETE FROM notifications WHERE agent=?;",
                    "DELETE FROM session_history WHERE agent=?;"] {
            guard let db else { continue }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, agent, -1, T)
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Export

    func exportJSON(agent: String? = nil) -> Data? {
        let rows = agent != nil ? recent(agent: agent!, limit: 10000) : recent(limit: 10000)
        let arr: [[String: Any]] = rows.map { r in
            var d: [String: Any] = [
                "id": r.id, "session_key": r.sessionKey, "agent": r.agent,
                "event": r.event, "ts": r.ts
            ]
            if let t = r.tool { d["tool"] = t }
            if let p = r.path { d["path"] = p }
            if let s = r.state { d["state"] = s }
            if let p = r.payload { d["payload"] = p }
            return d
        }
        return try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])
    }

    func exportCSV(agent: String? = nil) -> String {
        let rows = agent != nil ? recent(agent: agent!, limit: 10000) : recent(limit: 10000)
        var csv = "id,session_key,agent,event,tool,path,state,ts\n"
        for r in rows {
            let tool = r.tool ?? ""
            let path = r.path ?? ""
            let state = r.state ?? ""
            csv += "\(r.id),\(csvEscape(r.sessionKey)),\(csvEscape(r.agent)),\(csvEscape(r.event)),\(csvEscape(tool)),\(csvEscape(path)),\(csvEscape(state)),\(r.ts)\n"
        }
        return csv
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }

    // MARK: - Purge

    /// Hard row caps, audit 2026-06. The time-based retention in
    /// `retentionDays` is the primary control, but a fast event source
    /// (Claude Code firing PreToolUse for every file edit) can still
    /// produce tens of thousands of rows per hour. The caps below are
    /// the belt-and-braces ceiling; we keep the most-recent N rows
    /// regardless of age.
    static let maxEventsRows: Int = 50_000
    static let maxNotificationsRows: Int = 5_000
    static let maxSessionHistoryRows: Int = 5_000

    func purgeOld(olderThan seconds: TimeInterval? = nil) {
        let secs = seconds ?? TimeInterval(Self.retentionDays) * 24 * 3600
        let cutoff = Date().timeIntervalSince1970 - secs
        exec("DELETE FROM events WHERE ts < \(cutoff);")
        exec("DELETE FROM notifications WHERE ts < \(cutoff);")
        exec("DELETE FROM session_history WHERE ended_at < \(cutoff);")
        enforceRowCaps()
    }

    /// Caps the row count of each table to the configured maximums.
    /// Keeps the most-recent rows; deletes the oldest. Safe to call
    /// alongside the time-based purge; the two are independent safety
    /// nets.
    func enforceRowCaps() {
        // events
        exec("""
            DELETE FROM events WHERE id IN (
                SELECT id FROM events ORDER BY id DESC
                LIMIT -1 OFFSET \(Self.maxEventsRows)
            );
        """)
        // notifications
        exec("""
            DELETE FROM notifications WHERE id IN (
                SELECT id FROM notifications ORDER BY id DESC
                LIMIT -1 OFFSET \(Self.maxNotificationsRows)
            );
        """)
        // session_history
        exec("""
            DELETE FROM session_history WHERE id IN (
                SELECT id FROM session_history ORDER BY id DESC
                LIMIT -1 OFFSET \(Self.maxSessionHistoryRows)
            );
        """)
    }

    // MARK: - Internals

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let e = err { print("EventStore SQL error: \(String(cString: e))"); sqlite3_free(e) }
        }
    }

    private func str(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }
}
