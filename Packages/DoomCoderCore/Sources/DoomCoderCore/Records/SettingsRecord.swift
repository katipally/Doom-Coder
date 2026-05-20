import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// User-editable settings, mirrored bidirectionally. Each preference is a
/// separate field with its own `updatedAt_<field>` timestamp so we can
/// implement true per-field last-writer-wins merging on conflict
/// (§12.6 of the design plan).
public struct SettingsRecord: Sendable, Codable, Equatable {

    public var masterEnabled: Bool
    public var mode: String                    // "screenOn" | "screenOff"
    public var sessionTimerHrs: Int
    public var autoRevertSec: Int
    public var retentionDays: Int
    public var screenOffRearmMin: Int
    public var channelMacEnabled: Bool
    public var channeliOSEnabled: Bool
    /// 8 phase toggles (NotificationPrefs fields)
    public var prefSessionStart: Bool
    public var prefSessionEnd: Bool
    public var prefError: Bool
    public var prefPermissionNeeded: Bool
    public var prefAgentResponse: Bool
    public var prefSubagentStart: Bool
    public var prefSubagentEnd: Bool
    public var prefToolUse: Bool
    /// Per-agent channel overrides (agent rawValue → mac-enabled|ios-enabled).
    public var perAgentOverridesJSON: String   // {"claude":{"mac":true,"ios":false},...}
    /// Tier-2/3 privacy: when true, include payload snippets in iCloud sync.
    public var includePayloadSnippets: Bool

    /// Per-field update timestamps (seconds since 1970). Used for LWW merge.
    /// Each field above has a peer entry here.
    public var updatedAt: [String: Double]

    public var updatedBy: String               // macId or "iOS"
    public var schemaVersion: Int

    public init(masterEnabled: Bool = true,
                mode: String = "screenOn",
                sessionTimerHrs: Int = 0,
                autoRevertSec: Int = 30,
                retentionDays: Int = 7,
                screenOffRearmMin: Int = 10,
                channelMacEnabled: Bool = true,
                channeliOSEnabled: Bool = true,
                prefSessionStart: Bool = false,
                prefSessionEnd: Bool = true,
                prefError: Bool = true,
                prefPermissionNeeded: Bool = true,
                prefAgentResponse: Bool = false,
                prefSubagentStart: Bool = false,
                prefSubagentEnd: Bool = false,
                prefToolUse: Bool = false,
                perAgentOverridesJSON: String = "{}",
                includePayloadSnippets: Bool = false,
                updatedAt: [String: Double] = [:],
                updatedBy: String = "unknown",
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        self.masterEnabled = masterEnabled
        self.mode = mode
        self.sessionTimerHrs = sessionTimerHrs
        self.autoRevertSec = autoRevertSec
        self.retentionDays = retentionDays
        self.screenOffRearmMin = screenOffRearmMin
        self.channelMacEnabled = channelMacEnabled
        self.channeliOSEnabled = channeliOSEnabled
        self.prefSessionStart = prefSessionStart
        self.prefSessionEnd = prefSessionEnd
        self.prefError = prefError
        self.prefPermissionNeeded = prefPermissionNeeded
        self.prefAgentResponse = prefAgentResponse
        self.prefSubagentStart = prefSubagentStart
        self.prefSubagentEnd = prefSubagentEnd
        self.prefToolUse = prefToolUse
        self.perAgentOverridesJSON = perAgentOverridesJSON
        self.includePayloadSnippets = includePayloadSnippets
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.schemaVersion = schemaVersion
    }

    public static let singletonRecordName = "Settings-singleton"

    public static let allFieldKeys: [String] = [
        "masterEnabled", "mode", "sessionTimerHrs", "autoRevertSec",
        "retentionDays", "screenOffRearmMin",
        "channelMacEnabled", "channeliOSEnabled",
        "prefSessionStart", "prefSessionEnd", "prefError",
        "prefPermissionNeeded", "prefAgentResponse",
        "prefSubagentStart", "prefSubagentEnd", "prefToolUse",
        "perAgentOverridesJSON", "includePayloadSnippets",
    ]

    /// Merges `other` into `self`, keeping the field whose `updatedAt_<key>`
    /// is most recent. Per-field LWW (§12.6). Self is the "local" side.
    public mutating func merge(with other: SettingsRecord) {
        func pick<T>(_ key: String, _ lhs: T, _ rhs: T) -> T {
            let l = updatedAt[key] ?? 0
            let r = other.updatedAt[key] ?? 0
            return r > l ? rhs : lhs
        }
        masterEnabled        = pick("masterEnabled", masterEnabled, other.masterEnabled)
        mode                 = pick("mode", mode, other.mode)
        sessionTimerHrs      = pick("sessionTimerHrs", sessionTimerHrs, other.sessionTimerHrs)
        autoRevertSec        = pick("autoRevertSec", autoRevertSec, other.autoRevertSec)
        retentionDays        = pick("retentionDays", retentionDays, other.retentionDays)
        screenOffRearmMin    = pick("screenOffRearmMin", screenOffRearmMin, other.screenOffRearmMin)
        channelMacEnabled    = pick("channelMacEnabled", channelMacEnabled, other.channelMacEnabled)
        channeliOSEnabled    = pick("channeliOSEnabled", channeliOSEnabled, other.channeliOSEnabled)
        prefSessionStart     = pick("prefSessionStart", prefSessionStart, other.prefSessionStart)
        prefSessionEnd       = pick("prefSessionEnd", prefSessionEnd, other.prefSessionEnd)
        prefError            = pick("prefError", prefError, other.prefError)
        prefPermissionNeeded = pick("prefPermissionNeeded", prefPermissionNeeded, other.prefPermissionNeeded)
        prefAgentResponse    = pick("prefAgentResponse", prefAgentResponse, other.prefAgentResponse)
        prefSubagentStart    = pick("prefSubagentStart", prefSubagentStart, other.prefSubagentStart)
        prefSubagentEnd      = pick("prefSubagentEnd", prefSubagentEnd, other.prefSubagentEnd)
        prefToolUse          = pick("prefToolUse", prefToolUse, other.prefToolUse)
        perAgentOverridesJSON = pick("perAgentOverridesJSON", perAgentOverridesJSON, other.perAgentOverridesJSON)
        includePayloadSnippets = pick("includePayloadSnippets", includePayloadSnippets, other.includePayloadSnippets)

        // Adopt the per-key max of both sides into our timestamp map.
        var merged = updatedAt
        for k in Self.allFieldKeys {
            let l = updatedAt[k] ?? 0
            let r = other.updatedAt[k] ?? 0
            merged[k] = max(l, r)
        }
        updatedAt = merged
    }

    /// Stamps the given field's updatedAt to now. Call this every time you
    /// mutate a single field — never bulk-stamp.
    public mutating func touch(_ field: String, at date: Date = Date(), by updater: String) {
        updatedAt[field] = date.timeIntervalSince1970
        updatedBy = updater
    }
}

#if canImport(CloudKit)
extension SettingsRecord {
    public static let recordType = CloudKitConstants.RecordType.settings

    public static var recordID: CKRecord.ID {
        let zone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        return CKRecord.ID(recordName: singletonRecordName, zoneID: zone)
    }

    public func toCKRecord() -> CKRecord {
        let r = CKRecord(recordType: Self.recordType, recordID: Self.recordID)
        r["masterEnabled"]        = (masterEnabled ? 1 : 0) as CKRecordValue
        r["mode"]                 = mode as CKRecordValue
        r["sessionTimerHrs"]      = sessionTimerHrs as CKRecordValue
        r["autoRevertSec"]        = autoRevertSec as CKRecordValue
        r["retentionDays"]        = retentionDays as CKRecordValue
        r["screenOffRearmMin"]    = screenOffRearmMin as CKRecordValue
        r["channelMacEnabled"]    = (channelMacEnabled ? 1 : 0) as CKRecordValue
        r["channeliOSEnabled"]    = (channeliOSEnabled ? 1 : 0) as CKRecordValue
        r["prefSessionStart"]     = (prefSessionStart ? 1 : 0) as CKRecordValue
        r["prefSessionEnd"]       = (prefSessionEnd ? 1 : 0) as CKRecordValue
        r["prefError"]            = (prefError ? 1 : 0) as CKRecordValue
        r["prefPermissionNeeded"] = (prefPermissionNeeded ? 1 : 0) as CKRecordValue
        r["prefAgentResponse"]    = (prefAgentResponse ? 1 : 0) as CKRecordValue
        r["prefSubagentStart"]    = (prefSubagentStart ? 1 : 0) as CKRecordValue
        r["prefSubagentEnd"]      = (prefSubagentEnd ? 1 : 0) as CKRecordValue
        r["prefToolUse"]          = (prefToolUse ? 1 : 0) as CKRecordValue
        r["perAgentOverridesJSON"] = perAgentOverridesJSON as CKRecordValue
        r["includePayloadSnippets"] = (includePayloadSnippets ? 1 : 0) as CKRecordValue
        if let data = try? JSONEncoder().encode(updatedAt),
           let s = String(data: data, encoding: .utf8) {
            r["updatedAtJSON"]    = s as CKRecordValue
        }
        r["updatedBy"]            = updatedBy as CKRecordValue
        r["schemaVersion"]        = schemaVersion as CKRecordValue
        return r
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType else { return nil }
        let updatedAtMap: [String: Double] = {
            guard let s = r["updatedAtJSON"] as? String,
                  let d = s.data(using: .utf8),
                  let m = try? JSONDecoder().decode([String: Double].self, from: d)
            else { return [:] }
            return m
        }()
        self.init(
            masterEnabled: ((r["masterEnabled"] as? Int) ?? 1) != 0,
            mode: (r["mode"] as? String) ?? "screenOn",
            sessionTimerHrs: (r["sessionTimerHrs"] as? Int) ?? 0,
            autoRevertSec: (r["autoRevertSec"] as? Int) ?? 30,
            retentionDays: (r["retentionDays"] as? Int) ?? 7,
            screenOffRearmMin: (r["screenOffRearmMin"] as? Int) ?? 10,
            channelMacEnabled: ((r["channelMacEnabled"] as? Int) ?? 1) != 0,
            channeliOSEnabled: ((r["channeliOSEnabled"] as? Int) ?? 1) != 0,
            prefSessionStart: ((r["prefSessionStart"] as? Int) ?? 0) != 0,
            prefSessionEnd: ((r["prefSessionEnd"] as? Int) ?? 1) != 0,
            prefError: ((r["prefError"] as? Int) ?? 1) != 0,
            prefPermissionNeeded: ((r["prefPermissionNeeded"] as? Int) ?? 1) != 0,
            prefAgentResponse: ((r["prefAgentResponse"] as? Int) ?? 0) != 0,
            prefSubagentStart: ((r["prefSubagentStart"] as? Int) ?? 0) != 0,
            prefSubagentEnd: ((r["prefSubagentEnd"] as? Int) ?? 0) != 0,
            prefToolUse: ((r["prefToolUse"] as? Int) ?? 0) != 0,
            perAgentOverridesJSON: (r["perAgentOverridesJSON"] as? String) ?? "{}",
            includePayloadSnippets: ((r["includePayloadSnippets"] as? Int) ?? 0) != 0,
            updatedAt: updatedAtMap,
            updatedBy: (r["updatedBy"] as? String) ?? "unknown",
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
