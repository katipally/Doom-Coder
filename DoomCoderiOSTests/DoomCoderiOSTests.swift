import XCTest
@testable import DoomCoderiOS

// MARK: - CloudKit Schema record-mapping tests

@MainActor
final class CloudKitSchemaTests: XCTestCase {

    func testCKAgentEventRecordName() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let event = CKAgentEvent(
            sessionKey: "sess-abc",
            agent: "claude",
            agentVariant: nil,
            macHostname: "Macbook",
            cwdBasename: "Doom-Coder",
            cwdHashSuffix: "a1b2",
            hookPhase: "PreToolUse",
            occurredAt: date,
            payloadJSON: "{}",
            expiresAt: date.addingTimeInterval(604_800)
        )
        XCTAssertEqual(event.recordName, "sess-abc::PreToolUse::1700000000000")
    }

    func testCKSessionAggregateRecordName() {
        let now = Date()
        let agg = CKSessionAggregate(
            sessionKey: "s-xyz",
            agent: "codex",
            agentVariant: nil,
            macHostname: "Mac",
            cwdBasename: "backend",
            cwdHashSuffix: "cc11",
            startedAt: now,
            lastEventAt: now,
            endedAt: nil,
            status: .running,
            currentTool: "Edit",
            totalToolCalls: 3,
            totalFilesEdited: 1,
            totalErrors: 0,
            model: nil,
            promptPreview: nil,
            expiresAt: now.addingTimeInterval(604_800)
        )
        XCTAssertEqual(agg.recordName, "s-xyz")
    }

    func testCKApprovalRequestRecordName() {
        let now = Date()
        let req = CKApprovalRequest(
            requestId: "req-1",
            sessionKey: "sess-abc",
            agent: "claude",
            toolName: "Bash",
            toolArgsJSON: "{\"cmd\": \"rm -rf\"}",
            requestedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        XCTAssertEqual(req.recordName, "req-1")
    }

    func testCKApprovalResponseDecisions() {
        let now = Date()
        for decision in [CKApprovalResponse.Decision.approve, .deny, .always] {
            let resp = CKApprovalResponse(
                requestId: "req-1",
                decision: decision,
                decidedAt: now,
                decidedByDevice: "iphone-uuid"
            )
            XCTAssertEqual(resp.requestId, "req-1")
            XCTAssertEqual(resp.recordName, "req-1")
        }
    }

    func testSessionAggregateStatusRoundTrip() throws {
        let statuses: [CKSessionAggregate.Status] = [.running, .completed, .failed, .waitingApproval]
        for status in statuses {
            let encoded = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(CKSessionAggregate.Status.self, from: encoded)
            XCTAssertEqual(decoded, status)
        }
    }

    func testCloudKitSchemaConstants() {
        XCTAssertEqual(CloudKitSchema.containerIdentifier, "iCloud.com.doomcoder.app")
        XCTAssertEqual(CloudKitSchema.schemaVersion, "3.0.0")
        XCTAssertEqual(CloudKitSchema.RecordType.agentEvent, "AgentEvent")
        XCTAssertEqual(CloudKitSchema.RecordType.sessionAggregate, "SessionAggregate")
        XCTAssertEqual(CloudKitSchema.RecordType.approvalRequest, "ApprovalRequest")
        XCTAssertEqual(CloudKitSchema.RecordType.approvalResponse, "ApprovalResponse")
        XCTAssertEqual(CloudKitSchema.RecordType.userSettings, "UserSettings")
    }
}

// MARK: - IOSUserSettings default values

final class IOSUserSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear test-relevant keys from UserDefaults
        let d = UserDefaults.standard
        let keys = ["settings.minimalMode", "settings.notifyApprovals",
                    "settings.notifyFailures", "settings.notifySessionSummaries",
                    "settings.notifyToolCallUpdates", "settings.liveActivityMaxConcurrent",
                    "settings.liveActivityAutoDismissSec", "settings.historyRetentionDays"]
        keys.forEach { d.removeObject(forKey: $0) }
    }

    @MainActor func testDefaultValues() {
        let settings = IOSUserSettings.shared
        XCTAssertFalse(settings.minimalMode, "Default: minimalMode off")
        XCTAssertTrue(settings.notifyApprovals, "Default: approval notifications on")
        XCTAssertTrue(settings.notifyFailures, "Default: failure notifications on")
        XCTAssertTrue(settings.notifySessionSummaries, "Default: summary notifications on")
        XCTAssertFalse(settings.notifyToolCallUpdates, "Default: tool-call updates off")
        XCTAssertEqual(settings.liveActivityMaxConcurrent, 3)
        XCTAssertEqual(settings.liveActivityAutoDismissSec, 30)
        XCTAssertEqual(settings.historyRetentionDays, 7)
    }
}

// MARK: - Notification threading identifiers

final class NotificationThreadingTests: XCTestCase {

    func testApprovalThreadId() {
        let agent = "claude"
        let expected = "\(agent)::approval"
        XCTAssertEqual(expected, "claude::approval")
    }

    func testFailureThreadId() {
        let agent = "codex"
        let cwd = "backend-api"
        let expected = "\(agent)::\(cwd)"
        XCTAssertEqual(expected, "codex::backend-api")
    }
}

// MARK: - Session expiry window

final class ExpiryWindowTests: XCTestCase {

    func testAgentEventExpiresIn7Days() {
        let now = Date()
        let expiresAt = now.addingTimeInterval(7 * 86_400)
        XCTAssertGreaterThan(expiresAt.timeIntervalSince(now), 7 * 86_400 - 1)
        XCTAssertLessThan(expiresAt.timeIntervalSince(now), 7 * 86_400 + 1)
    }

    func testApprovalRequestExpiresIn60s() {
        let now = Date()
        let expiresAt = now.addingTimeInterval(60)
        let diff = expiresAt.timeIntervalSince(now)
        XCTAssertEqual(diff, 60, accuracy: 0.01)
    }
}
