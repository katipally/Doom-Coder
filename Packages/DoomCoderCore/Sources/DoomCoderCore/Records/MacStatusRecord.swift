import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Snapshot of a Mac's live state. One record per Mac, keyed by `macId`
/// (a stable identifier derived from the IOPlatformUUID).
///
/// Writer: Mac. Readers: iOS (Home tab header), NSE (notification subtitle
/// shows "<macName>").
public struct MacStatusRecord: Sendable, Codable, Equatable {
    public var macId: String
    public var name: String
    public var version: String
    public var sleepActive: Bool
    public var mode: String          // DoomCoderMode rawValue: "screenOn" | "screenOff"
    public var sessionEndsAt: Date?
    public var lastSeen: Date
    public var thermalState: String
    public var schemaVersion: Int
    /// Primary Ethernet/Wi-Fi MAC address ("aa:bb:cc:dd:ee:ff") so the
    /// iOS companion can send a magic packet over the local subnet when
    /// the Mac is asleep. Optional — over cellular WoL is impossible
    /// anyway and APNs wake-for-network is the canonical wake path.
    public var macAddress: String?
    /// IPv4 broadcast address of the primary interface (e.g. "192.168.1.255")
    /// so the magic packet reaches the correct subnet.
    public var broadcastIPv4: String?

    // MARK: - Keep-Awake state (schema v2+, additive — old clients ignore)

    /// User-selected keep-awake intent: "off" | "on" | "auto".
    /// Distinct from `sleepActive`, which reflects whether the assertion is
    /// CURRENTLY held (in Auto mode it toggles with agent activity).
    public var keepAwakeMode: String?
    /// Number of tracked agents currently in a live/active state. Drives the
    /// "awake because N agents working" subtitle in Auto mode.
    public var activeAgentCount: Int?
    /// Configured auto-off timer in hours (0 = never). Mirrors the dropdown.
    public var sessionTimerHours: Int?
    /// Elapsed seconds the current keep-awake session has been active.
    public var elapsedSeconds: Int?
    /// Ack channel: the last ControlCommand.commandId the Mac applied, so the
    /// iOS client can confirm its remote command landed.
    public var lastAppliedCommandId: String?
    /// When `lastAppliedCommandId` was applied.
    public var lastAppliedAt: Date?
    /// App-wide master suspend gate state ("master on/off"). `nil` on older Macs
    /// that predate remote master control — treated as ON for display.
    public var masterEnabled: Bool?

    // MARK: - Auto mode agent detail (additive, ignored by older clients)

    /// JSON-encoded array of active agent status lines for iOS rendering.
    /// Each element: {"name","raw","state","type","idleSecs","pidAlive"}.
    /// Only populated when keepAwakeMode == "auto".
    public var agentStatusJSON: String?
    /// The date at which the auto-mode grace period ends. Non-nil only while
    /// the 5-minute grace is ticking. Used by iOS for a live countdown.
    public var autoGraceEndsAt: Date?
    /// Dominant freshness signal: "agents" | "user_active" | "snoozed" | "idle".
    /// v2.6 (auto-mode redesign): iOS uses this to mirror the Mac's compact
    /// status pill — "2 agents working" / "You're active" / "Snoozed" / etc.
    public var autoSignal: String?
    /// True when the user has been at the keyboard / mouse / trackpad within
    /// the silence window. Drives the iOS "You're active" pill.
    public var isUserActive: Bool?
    /// True while a snooze override is in effect. iOS uses this to show the
    /// snooze banner on the Mac control card.
    public var isSnoozed: Bool?
    /// Snooze end time, or `nil` for an indefinite snooze. iOS renders a
    /// live countdown based on this.
    public var snoozeUntil: Date?
    /// Raw snooze duration string ("15m" | "1h" | "indefinite"). iOS shows
    /// the human label + countdown using this + `snoozeUntil`.
    public var snoozeDuration: String?

    public init(macId: String,
                name: String,
                version: String,
                sleepActive: Bool,
                mode: String,
                sessionEndsAt: Date? = nil,
                lastSeen: Date = Date(),
                thermalState: String = "Normal",
                macAddress: String? = nil,
                broadcastIPv4: String? = nil,
                keepAwakeMode: String? = nil,
                activeAgentCount: Int? = nil,
                sessionTimerHours: Int? = nil,
                elapsedSeconds: Int? = nil,
                lastAppliedCommandId: String? = nil,
                lastAppliedAt: Date? = nil,
                masterEnabled: Bool? = nil,
                agentStatusJSON: String? = nil,
                autoGraceEndsAt: Date? = nil,
                autoSignal: String? = nil,
                isUserActive: Bool? = nil,
                isSnoozed: Bool? = nil,
                snoozeUntil: Date? = nil,
                snoozeDuration: String? = nil,
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        self.macId = macId
        self.name = name
        self.version = version
        self.sleepActive = sleepActive
        self.mode = mode
        self.sessionEndsAt = sessionEndsAt
        self.lastSeen = lastSeen
        self.thermalState = thermalState
        self.macAddress = macAddress
        self.broadcastIPv4 = broadcastIPv4
        self.keepAwakeMode = keepAwakeMode
        self.activeAgentCount = activeAgentCount
        self.sessionTimerHours = sessionTimerHours
        self.elapsedSeconds = elapsedSeconds
        self.lastAppliedCommandId = lastAppliedCommandId
        self.lastAppliedAt = lastAppliedAt
        self.masterEnabled = masterEnabled
        self.agentStatusJSON = agentStatusJSON
        self.autoGraceEndsAt = autoGraceEndsAt
        self.autoSignal = autoSignal
        self.isUserActive = isUserActive
        self.isSnoozed = isSnoozed
        self.snoozeUntil = snoozeUntil
        self.snoozeDuration = snoozeDuration
        self.schemaVersion = schemaVersion
    }
}

#if canImport(CloudKit)
extension MacStatusRecord {
    public static let recordType = CloudKitConstants.RecordType.macStatus

    public var recordID: CKRecord.ID {
        let zone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        return CKRecord.ID(recordName: "MacStatus-\(macId)", zoneID: zone)
    }

    public func toCKRecord() -> CKRecord { toCKRecord(base: nil) }

    /// Builds a CKRecord for this status. If `base` is provided (the server
    /// CKRecord cached from the most recent fetch/save), its
    /// `recordChangeTag` is preserved by mutating it in place. Without the
    /// tag, every heartbeat looks like an INSERT to CloudKit and the second
    /// one fails with code 14/2004 ("record to insert already exists").
    public func toCKRecord(base: CKRecord?) -> CKRecord {
        let r = base ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        r["macId"]         = macId as CKRecordValue
        r["name"]          = name as CKRecordValue
        r["version"]       = version as CKRecordValue
        r["sleepActive"]   = (sleepActive ? 1 : 0) as CKRecordValue
        r["mode"]          = mode as CKRecordValue
        if let e = sessionEndsAt { r["sessionEndsAt"] = e as CKRecordValue }
        else { r["sessionEndsAt"] = nil }
        r["lastSeen"]      = lastSeen as CKRecordValue
        r["thermalState"]  = thermalState as CKRecordValue
        if let m = macAddress { r["macAddress"] = m as CKRecordValue } else { r["macAddress"] = nil }
        if let b = broadcastIPv4 { r["broadcastIPv4"] = b as CKRecordValue } else { r["broadcastIPv4"] = nil }
        if let k = keepAwakeMode { r["keepAwakeMode"] = k as CKRecordValue } else { r["keepAwakeMode"] = nil }
        if let a = activeAgentCount { r["activeAgentCount"] = a as CKRecordValue } else { r["activeAgentCount"] = nil }
        if let s = sessionTimerHours { r["sessionTimerHours"] = s as CKRecordValue } else { r["sessionTimerHours"] = nil }
        if let e = elapsedSeconds { r["elapsedSeconds"] = e as CKRecordValue } else { r["elapsedSeconds"] = nil }
        if let c = lastAppliedCommandId { r["lastAppliedCommandId"] = c as CKRecordValue } else { r["lastAppliedCommandId"] = nil }
        if let t = lastAppliedAt { r["lastAppliedAt"] = t as CKRecordValue } else { r["lastAppliedAt"] = nil }
        if let me = masterEnabled { r["masterEnabled"] = (me ? 1 : 0) as CKRecordValue } else { r["masterEnabled"] = nil }
        // agentStatusJSON / autoGraceEndsAt are new optional fields.
        // Only nil-clear them if they ALREADY exist in the base record — clearing
        // a field that has never been written causes CloudKit to reject the save
        // with a schema error, which silently breaks the MacStatus ack channel.
        if let j = agentStatusJSON {
            r["agentStatusJSON"] = j as CKRecordValue
        } else if r["agentStatusJSON"] != nil {
            r["agentStatusJSON"] = nil
        }
        if let g = autoGraceEndsAt {
            r["autoGraceEndsAt"] = g as CKRecordValue
        } else if r["autoGraceEndsAt"] != nil {
            r["autoGraceEndsAt"] = nil
        }
        // v2.6 (auto-mode redesign) — additive fields. Only nil-clear if they
        // already exist in the base record (clearing an unwritten field breaks
        // CloudKit saves with a schema error).
        if let s = autoSignal { r["autoSignal"] = s as CKRecordValue }
        else if r["autoSignal"] != nil { r["autoSignal"] = nil }
        if let u = isUserActive { r["isUserActive"] = (u ? 1 : 0) as CKRecordValue }
        else if r["isUserActive"] != nil { r["isUserActive"] = nil }
        if let sn = isSnoozed { r["isSnoozed"] = (sn ? 1 : 0) as CKRecordValue }
        else if r["isSnoozed"] != nil { r["isSnoozed"] = nil }
        if let u = snoozeUntil { r["snoozeUntil"] = u as CKRecordValue }
        else if r["snoozeUntil"] != nil { r["snoozeUntil"] = nil }
        if let s = snoozeDuration { r["snoozeDuration"] = s as CKRecordValue }
        else if r["snoozeDuration"] != nil { r["snoozeDuration"] = nil }
        r["schemaVersion"] = schemaVersion as CKRecordValue
        return r
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let macId    = r["macId"]   as? String,
              let name     = r["name"]    as? String,
              let version  = r["version"] as? String,
              let mode     = r["mode"]    as? String,
              let lastSeen = r["lastSeen"] as? Date else { return nil }
        let sleepActive = ((r["sleepActive"] as? Int) ?? 0) != 0
        self.init(
            macId: macId, name: name, version: version,
            sleepActive: sleepActive, mode: mode,
            sessionEndsAt: r["sessionEndsAt"] as? Date,
            lastSeen: lastSeen,
            thermalState: (r["thermalState"] as? String) ?? "Normal",
            macAddress: r["macAddress"] as? String,
            broadcastIPv4: r["broadcastIPv4"] as? String,
            keepAwakeMode: r["keepAwakeMode"] as? String,
            activeAgentCount: r["activeAgentCount"] as? Int,
            sessionTimerHours: r["sessionTimerHours"] as? Int,
            elapsedSeconds: r["elapsedSeconds"] as? Int,
            lastAppliedCommandId: r["lastAppliedCommandId"] as? String,
            lastAppliedAt: r["lastAppliedAt"] as? Date,
            masterEnabled: (r["masterEnabled"] as? Int).map { $0 != 0 },
            agentStatusJSON: r["agentStatusJSON"] as? String,
            autoGraceEndsAt: r["autoGraceEndsAt"] as? Date,
            autoSignal: r["autoSignal"] as? String,
            isUserActive: (r["isUserActive"] as? Int).map { $0 != 0 },
            isSnoozed: (r["isSnoozed"] as? Int).map { $0 != 0 },
            snoozeUntil: r["snoozeUntil"] as? Date,
            snoozeDuration: r["snoozeDuration"] as? String,
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
