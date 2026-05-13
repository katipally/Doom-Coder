import Foundation

enum CloudKitSchema {
    static let containerIdentifier = "iCloud.com.doomcoder.app"
    static let schemaVersion = "3.0.0"

    enum RecordType {
        static let agentEvent = "AgentEvent"
        static let sessionAggregate = "SessionAggregate"
        static let approvalRequest = "ApprovalRequest"
        static let approvalResponse = "ApprovalResponse"
        static let devicePresence = "DevicePresence"
        static let userSettings = "UserSettings"
        static let pushNotification = "PushNotification"
        static let sleepCommand = "SleepCommand"
    }
}

struct CKSleepCommand: Codable, Sendable {
    let commandId: String
    let commandType: String   // "toggle" | "setMode" | "setRearmMinutes" | "setTimerHours"
    let enabled: Int?         // 0 or 1 (for "toggle")
    let mode: String?         // "screenOn" | "screenOff" (for "setMode")
    let rearmMinutes: Int?    // for "setRearmMinutes"
    let timerHours: Int?      // for "setTimerHours"
    let issuedAt: Date
    let expiresAt: Date

    var recordName: String { commandId }
    static let recordType = "SleepCommand"
}

struct CKPushNotification: Codable, Sendable {
    let sessionKey: String
    let agent: String
    let title: String
    let body: String
    let phase: String
    let occurredAt: Date
    let expiresAt: Date

    var recordName: String { "\(sessionKey)::notify::\(Int(occurredAt.timeIntervalSince1970 * 1000))" }
}

struct CKAgentEvent: Codable, Sendable {
    let sessionKey: String
    let agent: String
    let agentVariant: String?
    let macHostname: String
    let cwdBasename: String
    let cwdHashSuffix: String
    let hookPhase: String
    let occurredAt: Date
    let payloadJSON: String
    let expiresAt: Date

    var recordName: String { "\(sessionKey)::\(hookPhase)::\(Int(occurredAt.timeIntervalSince1970 * 1000))" }

    var toolName: String? {
        guard let data = payloadJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (dict["tool_name"] as? String) ?? (dict["tool"] as? String)
    }

    var filePath: String? {
        guard let data = payloadJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (dict["file_path"] as? String)
            ?? ((dict["input"] as? [String: Any])?["file_path"] as? String)
            ?? (dict["path"] as? String)
    }
}

struct CKSessionAggregate: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case running, completed, failed, waitingApproval
    }

    let sessionKey: String
    var agent: String
    var agentVariant: String?
    var macHostname: String
    var cwdBasename: String
    var cwdHashSuffix: String
    var startedAt: Date
    var lastEventAt: Date
    var endedAt: Date?
    var status: Status
    var currentTool: String?
    var totalToolCalls: Int
    var totalFilesEdited: Int
    var totalErrors: Int
    var model: String?
    var promptPreview: String?
    var toolArgsPreview: String?
    var expiresAt: Date
    var pendingRequestId: String?

    var recordName: String { sessionKey }
}

struct CKApprovalRequest: Codable, Sendable {
    let requestId: String
    let sessionKey: String
    let agent: String
    let toolName: String
    let toolArgsJSON: String
    let requestedAt: Date
    let expiresAt: Date

    var recordName: String { requestId }
}

struct CKApprovalResponse: Codable, Sendable {
    enum Decision: String, Codable, Sendable {
        case approve, deny, always
    }

    let requestId: String
    let decision: Decision
    let decidedAt: Date
    let decidedByDevice: String

    var recordName: String { requestId }
}

struct CKDevicePresence: Codable, Sendable {
    enum Platform: String, Codable, Sendable {
        case macOS, iOS
    }

    let deviceUUID: String
    var deviceName: String
    var platform: Platform
    var appVersion: String
    var lastSeenAt: Date

    var recordName: String { deviceUUID }
}

struct CKUserSettings: Codable, Sendable {
    var minimalMode: Bool = false
    var notifyApprovals: Bool = true
    var notifyFailures: Bool = true
    var notifySessionSummaries: Bool = true
    var notifyToolCallUpdates: Bool = false
    var liveActivityMaxConcurrent: Int = 3
    var liveActivityAutoDismissSec: Int = 30
    var historyRetentionDays: Int = 7
    var lastModifiedBy: String
    var lastModifiedAt: Date

    var recordName: String { "settings" }
}
