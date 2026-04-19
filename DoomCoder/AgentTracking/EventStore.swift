import Foundation
import SQLite3

// Lightweight wrapper around SQLite for agent event history.
// Schema: events(id, session_key, agent, event, tool, path, state, ts)
// Auto-purges rows older than 7 days on open().
@MainActor
final class EventStore {
    static let shared = EventStore()

    // db is accessed only through insertQueue (writes) and from @MainActor (opens/reads).
    // Marking nonisolated(unsafe) lets the insertQueue closure reference it safely.
    nonisolated(unsafe) private var db: OpaquePointer?
    private let insertQueue = DispatchQueue(label: "com.doomcoder.EventStore.insert")

    private init() { open() }

    // MARK: - Lifecycle

    func open() {
        AgentSupportDir.ensure()
        let path = AgentSupportDir.dbURL.path
        if db != nil { return }
        if sqlite3_open(path, &db) != SQLITE_OK {
            db = nil
            return
        }
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
        purgeOld()
    }

    func close() {
        if db != nil { sqlite3_close(db); db = nil }
    }

    // MARK: - Writes

    nonisolated func insert(sessionKey: String, agent: String, event: String,
                            tool: String?, path: String?, state: String?, ts: TimeInterval) {
        let sql = "INSERT INTO events(session_key,agent,event,tool,path,state,ts) VALUES(?,?,?,?,?,?,?);"
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
            _ = sqlite3_step(stmt)
        }
    }

    // MARK: - Reads

    struct Row: Sendable {
        let id: Int64
        let sessionKey: String
        let agent: String
        let event: String
        let tool: String?
        let path: String?
        let state: String?
        let ts: TimeInterval
    }

    func recent(limit: Int = 200) -> [Row] {
        guard let db else { return [] }
        let sql = "SELECT id,session_key,agent,event,tool,path,state,ts FROM events ORDER BY id DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
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
                ts: sqlite3_column_double(stmt, 7)
            ))
        }
        return rows
    }

    // MARK: - Purge

    func purgeOld(olderThan seconds: TimeInterval = 7 * 24 * 3600) {
        let cutoff = Date().timeIntervalSince1970 - seconds
        exec("DELETE FROM events WHERE ts < \(cutoff);")
    }

    // MARK: - Internals

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err { sqlite3_free(err) }
        }
    }

    private func str(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }
}
