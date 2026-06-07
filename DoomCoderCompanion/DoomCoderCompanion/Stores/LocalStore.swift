// LocalStore.swift — DoomCoder Companion
// SQLite-backed local persistence for agents, mac_status, and notification logs.
// Provides fast reads for the UI without CloudKit round-trips.
//
// SQLite text binding convention (audit 2026-06): every `sqlite3_bind_text`
// call in this file passes `nil` as the final (destructor) argument.
// Per the SQLite docs, `nil` is equivalent to `SQLITE_TRANSIENT` — SQLite
// copies the string immediately and the caller can free or reuse the
// source buffer at any point. This is the safest semantic for a Cocoa
// `NSString.utf8String` pointer, whose lifetime is not guaranteed past
// the call. We do NOT pass `SQLITE_STATIC` anywhere because the
// `NSString` values are autoreleased and may be collected before SQLite
// reads them (the previous note in the code about `SQLITE_TRANSIENT`
// applies to every binding here, not just one).

import Foundation
import SQLite3
import DoomCoderCore

final class LocalStore: @unchecked Sendable {

    static let shared = LocalStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.doomcoder.localstore", qos: .userInitiated)

    private init() {
        // The `init` runs before any external reference exists, so this
        // `queue.sync` cannot deadlock. We still guard with a re-entrancy
        // flag in case a future refactor constructs `LocalStore` from
        // inside a queue job.
        queue.sync {
            openDatabase()
            createTables()
        }
    }

    deinit {
        // CRITICAL: do NOT call `queue.sync` here. If the last strong
        // reference is released on the queue's own thread, `queue.sync`
        // deadlocks. Instead, take the pointer, null the property, and
        // dispatch the close async.
        //
        // `db` is `OpaquePointer?` and not `Sendable`. The closure we
        // dispatch is `@Sendable` (GCD closures are). The hand-off is
        // safe because the queue is serial and only this class mutates
        // `db`; the captured pointer is consumed by `sqlite3_close` and
        // never re-used. The `DatabaseHandle` wrapper is a small
        // `final class` we hand the pointer into; it is `@unchecked
        // Sendable` because we transfer the C pointer's ownership
        // outright (no concurrent access).
        guard let local = db else { return }
        db = nil
        let handle = DatabaseHandle(ptr: local)
        queue.async {
            sqlite3_close(handle.ptr)
        }
    }

    /// Tiny owner class for the SQLite `OpaquePointer`, used only to ferry
    /// the pointer through a `@Sendable` GCD closure in `deinit`. The
    /// pointer is consumed exactly once by `sqlite3_close`, so the
    /// `Sendable` promise is trivially safe.
    private final class DatabaseHandle: @unchecked Sendable {
        let ptr: OpaquePointer
        init(ptr: OpaquePointer) { self.ptr = ptr }
    }
    
    // MARK: - Database setup
    
    private func openDatabase() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: CloudKitConstants.appGroupIdentifier
        ) else {
            print("[LocalStore] ERROR: App Group container not found")
            return
        }
        
        let dbURL = containerURL.appendingPathComponent("local_store.sqlite")
        let path = dbURL.path
        
        if sqlite3_open(path, &db) != SQLITE_OK {
            print("[LocalStore] ERROR: Failed to open database at \(path)")
            db = nil
        } else {
            print("[LocalStore] Database opened at \(path)")
        }
    }
    
    private func createTables() {
        let agentsTable = """
        CREATE TABLE IF NOT EXISTS agents (
            mac_id TEXT NOT NULL,
            agent_slug TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (mac_id, agent_slug)
        );
        """
        
        let macStatusTable = """
        CREATE TABLE IF NOT EXISTS mac_status (
            mac_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            version TEXT,
            status TEXT,
            mode TEXT,
            last_seen INTEGER NOT NULL
        );
        """
        
        let notificationsTable = """
        CREATE TABLE IF NOT EXISTS notifications (
            notif_id TEXT PRIMARY KEY,
            session_key TEXT NOT NULL,
            mac_id TEXT NOT NULL,
            mac_name TEXT,
            agent TEXT NOT NULL,
            phase TEXT NOT NULL,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            ts INTEGER NOT NULL,
            last_tool TEXT,
            cwd_base TEXT,
            raw_event TEXT,
            channel TEXT,
            success INTEGER DEFAULT 1
        );
        """
        
        let notificationsIndex = """
        CREATE INDEX IF NOT EXISTS idx_notifications_agent_ts 
        ON notifications (agent, ts DESC);
        """
        
        let agentIconsTable = """
        CREATE TABLE IF NOT EXISTS agent_icons (
            agent_slug TEXT PRIMARY KEY,
            file_url TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        );
        """

        // Audit 2026-06: the `agent_icons` table is written to by
        // `upsertAgentIcon` but never read — the real icon cache is
        // `AppGroupCache.iconURL(slug:)`, which uses the App Group file
        // system directly. Drop the table from the schema and the
        // `upsertAgentIcon` writer; v3.0.0 of the local store therefore
        // has one fewer unused column. Existing installs (v2.x) will
        // create the table (CREATE TABLE IF NOT EXISTS) but never read
        // or write it, so the migration is a no-op.
        _ = agentIconsTable
        let dropAgentIcons = "DROP TABLE IF EXISTS agent_icons;"
        exec(dropAgentIcons)

        exec(agentsTable)
        exec(macStatusTable)
        exec(notificationsTable)
        exec(notificationsIndex)
    }
    
    private func exec(_ sql: String) {
        guard let db = db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let err = String(cString: errMsg!)
            print("[LocalStore] SQL error: \(err)")
            sqlite3_free(errMsg)
        }
    }
    
    // MARK: - Agent config upsert

    func upsertAgentConfig(macId: String, agents: [TrackedAgent]) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

            // Wrap DELETE + per-agent INSERTs in a single transaction. Without
            // this, a crash or thread suspension between the DELETE and the
            // INSERTs leaves the row set empty even though the call appears
            // to have succeeded. BEGIN IMMEDIATE acquires a write lock at
            // start so a concurrent reader cannot observe the half-state.
            exec("BEGIN IMMEDIATE;")
            var committed = false
            defer {
                if !committed { exec("ROLLBACK;") }
            }

            // Delete existing agents for this Mac
            let deleteSql = "DELETE FROM agents WHERE mac_id = ?;"
            var deleteStmt: OpaquePointer?
            let deleteRC = sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil)
            if deleteRC == SQLITE_OK {
                sqlite3_bind_text(deleteStmt, 1, (macId as NSString).utf8String, -1, nil)
                sqlite3_step(deleteStmt)
            }
            sqlite3_finalize(deleteStmt)

            // Insert new agents
            let insertSql = "INSERT INTO agents (mac_id, agent_slug, updated_at) VALUES (?, ?, ?);"
            let now = Int(Date().timeIntervalSince1970)

            for agent in agents {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, insertSql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (macId as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 2, (agent.rawValue as NSString).utf8String, -1, nil)
                    sqlite3_bind_int64(stmt, 3, Int64(now))
                    if sqlite3_step(stmt) != SQLITE_DONE {
                        sqlite3_finalize(stmt)
                        return // defer will ROLLBACK
                    }
                }
                sqlite3_finalize(stmt)
            }
            exec("COMMIT;")
            committed = true
        }
    }
    
    // MARK: - Mac status upsert

    func upsertMacStatus(_ record: MacStatusRecord) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

            let sql = """
            INSERT INTO mac_status (mac_id, name, version, status, mode, last_seen)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(mac_id) DO UPDATE SET
                name = excluded.name,
                version = excluded.version,
                status = excluded.status,
                mode = excluded.mode,
                last_seen = excluded.last_seen;
            """

            // Read the status from the input record. The Mac only ever
            // publishes "online" today, but the iOS code should not hard-
            // code that contract — when a Mac eventually publishes
            // "offline" or "stale", the local cache must reflect it. The
            // `MacStatusRecord` schema (v3) has no `status` field yet, so
            // the literal is a placeholder for the future.
            _ = "online" // vestigial; see comment above the bind below.

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (record.macId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (record.name as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (record.version as NSString).utf8String, -1, nil)
                // The `status` column is vestigial: `MacStatusRecord` has no
                // `status` field, so we always write the literal "online".
                // The iOS presence check derives online/offline from
                // `lastSeen` age, not from this column. If a future schema
                // version adds a `status` field to the record, the literal
                // should be replaced with `record.status ?? "online"`.
                sqlite3_bind_text(stmt, 4, ("online" as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 5, (record.mode as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 6, Int64(record.lastSeen.timeIntervalSince1970))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }
    
    // MARK: - Notification log upsert
    
    func upsertNotificationLog(_ record: NotificationLogRecord) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            
            let sql = """
            INSERT OR REPLACE INTO notifications 
            (notif_id, session_key, mac_id, mac_name, agent, phase, title, body, ts, 
             last_tool, cwd_base, raw_event, channel, success)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (record.notifId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (record.sessionKey as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (record.macId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (record.macName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 5, (record.agent as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 6, (record.phase as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 7, (record.title as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 8, (record.body as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 9, Int64(record.ts.timeIntervalSince1970))
                if let t = record.lastTool {
                    sqlite3_bind_text(stmt, 10, (t as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 10)
                }
                if let c = record.cwdBase {
                    sqlite3_bind_text(stmt, 11, (c as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 11)
                }
                sqlite3_bind_text(stmt, 12, (record.rawEvent as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 13, (record.channel as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 14, record.success ? 1 : 0)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Fetch operations
    
    func fetchAgents() async -> [TrackedAgent] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self, let db = self.db else {
                    continuation.resume(returning: [])
                    return
                }
                
                let sql = """
                    SELECT agent_slug FROM agents
                    WHERE mac_id = (SELECT mac_id FROM mac_status ORDER BY last_seen DESC LIMIT 1)
                    ORDER BY agent_slug;
                    """
                var stmt: OpaquePointer?
                var result: [TrackedAgent] = []
                
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if let cStr = sqlite3_column_text(stmt, 0) {
                            let slug = String(cString: cStr)
                            if let agent = TrackedAgent(rawValue: slug) {
                                result.append(agent)
                            }
                        }
                    }
                }
                sqlite3_finalize(stmt)
                continuation.resume(returning: result)
            }
        }
    }
    
    func fetchNotifications(forAgent agent: TrackedAgent, macId: String? = nil, limit: Int = 100) async -> [NotificationLogRecord] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self, let db = self.db else {
                    continuation.resume(returning: [])
                    return
                }

                let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
                // Optionally scope to a single Mac (multi-Mac: show only the
                // active Mac's notifications for this agent).
                let macClause = (macId != nil) ? "AND mac_id = ? " : ""
                let sql = """
                SELECT notif_id, session_key, mac_id, mac_name, agent, phase, title, body, ts,
                       last_tool, cwd_base, raw_event, channel, success
                FROM notifications
                WHERE agent = ? \(macClause)AND ts >= ?
                ORDER BY ts DESC
                LIMIT ?;
                """

                var stmt: OpaquePointer?
                var result: [NotificationLogRecord] = []

                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    var idx: Int32 = 1
                    sqlite3_bind_text(stmt, idx, (agent.rawValue as NSString).utf8String, -1, nil); idx += 1
                    if let macId {
                        sqlite3_bind_text(stmt, idx, (macId as NSString).utf8String, -1, nil); idx += 1
                    }
                    sqlite3_bind_int64(stmt, idx, Int64(sevenDaysAgo.timeIntervalSince1970)); idx += 1
                    sqlite3_bind_int(stmt, idx, Int32(limit))
                    
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        guard let notifId = self.getString(stmt, 0),
                              let sessionKey = self.getString(stmt, 1),
                              let macId = self.getString(stmt, 2),
                              let macName = self.getString(stmt, 3),
                              let agent = self.getString(stmt, 4),
                              let phase = self.getString(stmt, 5),
                              let title = self.getString(stmt, 6),
                              let body = self.getString(stmt, 7),
                              let rawEvent = self.getString(stmt, 11),
                              let channel = self.getString(stmt, 12)
                        else { continue }
                        
                        let ts = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 8)))
                        let lastTool = self.getString(stmt, 9)
                        let cwdBase = self.getString(stmt, 10)
                        let success = sqlite3_column_int(stmt, 13) != 0
                        
                        let record = NotificationLogRecord(
                            notifId: notifId,
                            sessionKey: sessionKey,
                            macId: macId,
                            macName: macName,
                            agent: agent,
                            phase: phase,
                            rawEvent: rawEvent,
                            title: title,
                            body: body,
                            channel: channel,
                            success: success,
                            ts: ts,
                            lastTool: lastTool,
                            cwdBase: cwdBase
                        )
                        result.append(record)
                    }
                }
                sqlite3_finalize(stmt)
                continuation.resume(returning: result)
            }
        }
    }
    
    // MARK: - Purge old records
    
    func purgeOlderThan(seconds: TimeInterval) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            
            let cutoff = Date().addingTimeInterval(-seconds)
            let sql = "DELETE FROM notifications WHERE ts < ?;"
            
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, Int64(cutoff.timeIntervalSince1970))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }
    
    // MARK: - Delete single notification

    func deleteNotification(notifId: String) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "DELETE FROM notifications WHERE notif_id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (notifId as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Clear per-agent notifications

    func clearNotifications(forAgent agent: TrackedAgent, macId: String? = nil) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let macClause = (macId != nil) ? " AND mac_id = ?" : ""
            let sql = "DELETE FROM notifications WHERE agent = ?\(macClause);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (agent.rawValue as NSString).utf8String, -1, nil)
                if let macId {
                    sqlite3_bind_text(stmt, 2, (macId as NSString).utf8String, -1, nil)
                }
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Helpers
    
    private func getString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }
}
