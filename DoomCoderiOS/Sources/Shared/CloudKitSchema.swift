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
    }
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
    var expiresAt: Date

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
