// LocalStore.swift — DoomCoder Companion
// SQLite-backed local persistence for agents, mac_status, and notification logs.
// Provides fast reads for the UI without CloudKit round-trips.

import Foundation
import SQLite3
import DoomCoderCore

final class LocalStore: @unchecked Sendable {
    
    static let shared = LocalStore()
    
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.doomcoder.localstore", qos: .userInitiated)
    
    private init() {
        queue.sync {
            openDatabase()
            createTables()
            runV28ConnectionMigration()
            createUniqueIndex()
        }
    }
    
    deinit {
        queue.sync {
            if let db = db {
                sqlite3_close(db)
            }
        }
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

        let devicesTable = """
        CREATE TABLE IF NOT EXISTS devices (
            device_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            route_tag TEXT NOT NULL,
            route_payload TEXT,
            last_seen INTEGER,
            capabilities TEXT,
            created_at INTEGER NOT NULL
        );
        """

        let connectionsTable = """
        CREATE TABLE IF NOT EXISTS connections (
            id TEXT PRIMARY KEY,
            mac_device_id TEXT NOT NULL,
            ios_device_id TEXT NOT NULL,
            route_tag TEXT NOT NULL,
            route_payload TEXT,
            status TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            last_sync_at INTEGER,
            share_url TEXT,
            share_owner TEXT,
            share_container TEXT,
            pairing_origin TEXT NOT NULL DEFAULT 'auto',
            state_change_counter INTEGER NOT NULL DEFAULT 1,
            removed_at INTEGER,
            share_accepted_at INTEGER
        );
        """

        exec(agentsTable)
        exec(macStatusTable)
        exec(notificationsTable)
        exec(notificationsIndex)
        exec(agentIconsTable)
        exec(devicesTable)
        exec(connectionsTable)
        // v5: additive columns. ADD COLUMN with default is safe on existing
        // rows — they're back-filled with the default value. Idempotent
        // guard via PRAGMA check so re-running on an already-migrated
        // table is a no-op.
        addColumnIfMissing(
            table: "connections", column: "pairing_origin",
            ddl: "ALTER TABLE connections ADD COLUMN pairing_origin TEXT NOT NULL DEFAULT 'auto';"
        )
        addColumnIfMissing(
            table: "connections", column: "state_change_counter",
            ddl: "ALTER TABLE connections ADD COLUMN state_change_counter INTEGER NOT NULL DEFAULT 1;"
        )
        addColumnIfMissing(
            table: "connections", column: "removed_at",
            ddl: "ALTER TABLE connections ADD COLUMN removed_at INTEGER;"
        )
        addColumnIfMissing(
            table: "connections", column: "share_accepted_at",
            ddl: "ALTER TABLE connections ADD COLUMN share_accepted_at INTEGER;"
        )
    }

    private func addColumnIfMissing(table: String, column: String, ddl: String) {
        guard let db = db else { return }
        let probe = "PRAGMA table_info(\(table));"
        var stmt: OpaquePointer?
        var exists = false
        if sqlite3_prepare_v2(db, probe, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cName = sqlite3_column_text(stmt, 1) {
                    if String(cString: cName) == column { exists = true; break }
                }
            }
        }
        sqlite3_finalize(stmt)
        if !exists { exec(ddl) }
    }

    /// v2.8: partial UNIQUE index on (mac_device_id, share_url).
    /// Prevents the duplicate-Connection scenarios that the audit
    /// found (re-pair, two-Mac-pairing, iOS-reinstall, etc.). The
    /// partial WHERE clause is necessary because implicit-iCloud
    /// rows have share_url = NULL and a plain UNIQUE constraint
    /// would only allow ONE such row in the table.
    private func createUniqueIndex() {
        exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_conn_share ON connections (mac_device_id, share_url) WHERE share_url IS NOT NULL;")
    }

    /// v2.8: one-shot wipe of legacy connections on first launch.
    /// The previous schema used random UUIDs for Connection.id, so
    /// every re-pair or re-install created a new row. The v2.8
    /// deterministic id scheme is incompatible at the row level —
    /// cleaner to wipe once and let the new engine auto-register
    /// fresh rows on the first MacStatus / CKShare arrival.
    private func runV28ConnectionMigration() {
        let key = "doomcoder.localstore.v28.wipedConnections"
        let defaults = AppGroupCache.defaults
        if defaults.bool(forKey: key) { return }
        exec("DELETE FROM connections;")
        defaults.set(true, forKey: key)
        print("[LocalStore] v2.8: wiped legacy connections table (one-shot migration)")
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
            
            // Delete existing agents for this Mac
            let deleteSql = "DELETE FROM agents WHERE mac_id = ?;"
            var deleteStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK {
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
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
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
    
    // MARK: - Agent icon upsert
    
    func upsertAgentIcon(slug: String, fileURL: URL) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            
            let sql = """
            INSERT OR REPLACE INTO agent_icons (agent_slug, file_url, updated_at)
            VALUES (?, ?, ?);
            """
            
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (slug as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (fileURL.path as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970))
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
                // v6: optional per-Mac filter so the multi-Mac switcher shows
                // each Mac's own logs.
                let macFilter = (macId?.isEmpty == false) ? "AND mac_id = ?" : ""
                let sql = """
                SELECT notif_id, session_key, mac_id, mac_name, agent, phase, title, body, ts,
                       last_tool, cwd_base, raw_event, channel, success
                FROM notifications
                WHERE agent = ? AND ts >= ? \(macFilter)
                ORDER BY ts DESC
                LIMIT ?;
                """

                var stmt: OpaquePointer?
                var result: [NotificationLogRecord] = []

                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (agent.rawValue as NSString).utf8String, -1, nil)
                    sqlite3_bind_int64(stmt, 2, Int64(sevenDaysAgo.timeIntervalSince1970))
                    var nextIdx: Int32 = 3
                    if let macId, !macId.isEmpty {
                        sqlite3_bind_text(stmt, nextIdx, (macId as NSString).utf8String, -1, nil)
                        nextIdx += 1
                    }
                    sqlite3_bind_int(stmt, nextIdx, Int32(limit))
                    
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

    func clearNotifications(forAgent agent: TrackedAgent) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "DELETE FROM notifications WHERE agent = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (agent.rawValue as NSString).utf8String, -1, nil)
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

    // MARK: - Devices

    func upsertDevice(_ d: DeviceProfile) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let route = d.route
            let routePayload: String
            if let data = try? JSONEncoder().encode(route),
               let str = String(data: data, encoding: .utf8) {
                routePayload = str
            } else {
                routePayload = ""
            }
            let sql = """
            INSERT INTO devices (device_id, name, kind, route_tag, route_payload, last_seen, capabilities, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(device_id) DO UPDATE SET
                name = excluded.name,
                kind = excluded.kind,
                route_tag = excluded.route_tag,
                route_payload = excluded.route_payload,
                last_seen = excluded.last_seen,
                capabilities = excluded.capabilities;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (d.id as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (d.name as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (d.kind.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (route.tag.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 5, (routePayload as NSString).utf8String, -1, nil)
                if let lastSeen = d.lastSeen {
                    sqlite3_bind_int64(stmt, 6, Int64(lastSeen.timeIntervalSince1970))
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                sqlite3_bind_text(stmt, 7, (d.capabilities.joined(separator: ",") as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 8, Int64(d.createdAt.timeIntervalSince1970))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func deleteDevice(id: String) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "DELETE FROM devices WHERE device_id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func fetchDevices() async -> [DeviceProfile] {
        await withCheckedContinuation { cont in
            queue.async { [weak self] in
                guard let self, let db = self.db else {
                    cont.resume(returning: [])
                    return
                }
                var stmt: OpaquePointer?
                let sql = "SELECT device_id, name, kind, route_tag, route_payload, last_seen, capabilities, created_at FROM devices;"
                var results: [DeviceProfile] = []
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        guard let idStr = getString(stmt, 0),
                              let nameStr = getString(stmt, 1),
                              let kindStr = getString(stmt, 2),
                              let kind = DeviceKind(rawValue: kindStr) else { continue }
                        let routeTag = getString(stmt, 3) ?? "iCloud"
                        let routePayload = getString(stmt, 4) ?? ""
                        let lastSeen: Date? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                            ? nil
                            : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 5)))
                        let caps = (getString(stmt, 6) ?? "")
                            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
                        let createdAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7)))
                        let route: Route = {
                            if routeTag == Route.Tag.ckShare.rawValue,
                               let data = routePayload.data(using: .utf8),
                               let decoded = try? JSONDecoder().decode(Route.self, from: data) {
                                return decoded
                            }
                            return .iCloud
                        }()
                        results.append(DeviceProfile(
                            id: idStr,
                            name: nameStr,
                            kind: kind,
                            route: route,
                            lastSeen: lastSeen,
                            capabilities: caps,
                            createdAt: createdAt
                        ))
                    }
                }
                sqlite3_finalize(stmt)
                cont.resume(returning: results)
            }
        }
    }

    // MARK: - Connections

    func upsertConnection(_ c: Connection) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let route = c.route
            let routePayload: String
            if let data = try? JSONEncoder().encode(route),
               let str = String(data: data, encoding: .utf8) {
                routePayload = str
            } else {
                routePayload = ""
            }
            let sql = """
            INSERT INTO connections (id, mac_device_id, ios_device_id, route_tag, route_payload, status, created_at, last_sync_at, share_url, share_owner, share_container, pairing_origin, state_change_counter, removed_at, share_accepted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                mac_device_id = excluded.mac_device_id,
                ios_device_id = excluded.ios_device_id,
                route_tag = excluded.route_tag,
                route_payload = excluded.route_payload,
                status = excluded.status,
                last_sync_at = excluded.last_sync_at,
                share_url = excluded.share_url,
                share_owner = excluded.share_owner,
                share_container = excluded.share_container,
                pairing_origin = excluded.pairing_origin,
                state_change_counter = excluded.state_change_counter,
                removed_at = excluded.removed_at,
                share_accepted_at = excluded.share_accepted_at;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (c.id as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (c.macDeviceId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (c.iosDeviceId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (route.tag.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 5, (routePayload as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 6, (c.status.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 7, Int64(c.createdAt.timeIntervalSince1970))
                if let last = c.lastSyncAt {
                    sqlite3_bind_int64(stmt, 8, Int64(last.timeIntervalSince1970))
                } else {
                    sqlite3_bind_null(stmt, 8)
                }
                if let s = c.ckShareRef {
                    sqlite3_bind_text(stmt, 9, (s.shareURLString as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 10, (s.ownerRecordName as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 11, (s.containerIdentifier as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 9)
                    sqlite3_bind_null(stmt, 10)
                    sqlite3_bind_null(stmt, 11)
                }
                sqlite3_bind_text(stmt, 12, (c.pairingOrigin.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 13, Int32(c.stateChangeCounter))
                if let removedAt = c.removedAt {
                    sqlite3_bind_int64(stmt, 14, Int64(removedAt.timeIntervalSince1970))
                } else {
                    sqlite3_bind_null(stmt, 14)
                }
                if let accepted = c.shareAcceptedAt {
                    sqlite3_bind_int64(stmt, 15, Int64(accepted.timeIntervalSince1970))
                } else {
                    sqlite3_bind_null(stmt, 15)
                }
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func deleteConnection(id: String) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "DELETE FROM connections WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func fetchConnections() async -> [Connection] {
        await withCheckedContinuation { cont in
            queue.async { [weak self] in
                guard let self, let db = self.db else {
                    cont.resume(returning: [])
                    return
                }
                var stmt: OpaquePointer?
                let sql = "SELECT id, mac_device_id, ios_device_id, route_tag, route_payload, status, created_at, last_sync_at, share_url, share_owner, share_container, pairing_origin, state_change_counter, removed_at, share_accepted_at FROM connections;"
                var results: [Connection] = []
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        guard let idStr = getString(stmt, 0),
                              let macId = getString(stmt, 1),
                              let iosId = getString(stmt, 2),
                              let statusStr = getString(stmt, 5),
                              let status = ConnectionStatus(rawValue: statusStr)
                        else { continue }
                        let routeTag = getString(stmt, 3) ?? "iCloud"
                        let routePayload = getString(stmt, 4) ?? ""
                        let route: Route = {
                            if routeTag == Route.Tag.ckShare.rawValue,
                               let data = routePayload.data(using: .utf8),
                               let decoded = try? JSONDecoder().decode(Route.self, from: data) {
                                return decoded
                            }
                            return .iCloud
                        }()
                        let createdAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 6)))
                        let lastSync: Date? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
                            ? nil
                            : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7)))
                        var ref: CKShareRef?
                        if let url = getString(stmt, 8),
                           let owner = getString(stmt, 9),
                           let container = getString(stmt, 10) {
                            ref = CKShareRef(shareURLString: url, ownerRecordName: owner, containerIdentifier: container)
                        }
                        let originStr = getString(stmt, 11) ?? PairingOrigin.auto.rawValue
                        let origin = PairingOrigin(rawValue: originStr) ?? .auto
                        let counter = Int(sqlite3_column_int(stmt, 12))
                        let removedAt: Date? = sqlite3_column_type(stmt, 13) == SQLITE_NULL
                            ? nil
                            : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 13)))
                        let shareAcceptedAt: Date? = sqlite3_column_type(stmt, 14) == SQLITE_NULL
                            ? nil
                            : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 14)))
                        results.append(Connection(
                            id: idStr,
                            macDeviceId: macId,
                            iosDeviceId: iosId,
                            route: route,
                            status: status,
                            createdAt: createdAt,
                            lastSyncAt: lastSync,
                            ckShareRef: ref,
                            pairingOrigin: origin,
                            stateChangeCounter: counter,
                            removedAt: removedAt,
                            shareAcceptedAt: shareAcceptedAt
                        ))
                    }
                }
                sqlite3_finalize(stmt)
                cont.resume(returning: results)
            }
        }
    }

    // MARK: - Clear per-Mac data on remove

    /// Wipe local cache entries that belong to a specific Mac. Called when
    /// the user removes a paired connection on iOS so the app no longer
    /// holds that Mac's status, agents, or notifications.
    func clearMacData(macId: String) async {
        await withCheckedContinuation { cont in
            queue.async { [weak self] in
                guard let self, let db = self.db else {
                    cont.resume()
                    return
                }
                for sql in [
                    "DELETE FROM mac_status WHERE mac_id = ?;",
                    "DELETE FROM agents WHERE mac_id = ?;",
                    "DELETE FROM notifications WHERE mac_id = ?;"
                ] {
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                        sqlite3_bind_text(stmt, 1, (macId as NSString).utf8String, -1, nil)
                        sqlite3_step(stmt)
                    }
                    sqlite3_finalize(stmt)
                }
                cont.resume()
            }
        }
    }
}
