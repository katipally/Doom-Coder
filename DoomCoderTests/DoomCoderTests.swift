@testable import DoomCoder
import XCTest

// MARK: - Redactor tests (Gate G6)

final class RedactorTests: XCTestCase {
    func testAWSKeyRedacted() {
        let input = "aws_access_key=AKIAIOSFODNN7EXAMPLE"
        XCTAssertTrue(Redactor.redact(input).contains("«redacted»"))
    }

    func testGitHubPATRedacted() {
        let input = "token: ghp_abcdefghijklmnopqrstuvwxyz123456789012"
        XCTAssertTrue(Redactor.redact(input).contains("«redacted»"))
    }

    func testOpenAIKeyRedacted() {
        let input = "api_key = sk-abcdef1234567890abcdef1234567890abcdef"
        XCTAssertTrue(Redactor.redact(input).contains("«redacted»"))
    }

    func testJWTRedacted() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        XCTAssertTrue(Redactor.redact(jwt).contains("«redacted»"))
    }

    func testBearerTokenRedacted() {
        let input = "Authorization: Bearer eyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456"
        XCTAssertTrue(Redactor.redact(input).contains("«redacted»"))
    }

    func testSafeTextUnchanged() {
        let safe = "Edit SleepManager.swift — 42 lines changed"
        XCTAssertEqual(Redactor.redact(safe), safe)
    }

    func testMinimalEventStripsPayload() {
        let event = CKAgentEvent(
            sessionKey: "s1", agent: "claude", agentVariant: nil,
            macHostname: "Mac", cwdBasename: "Doom-Coder", cwdHashSuffix: "ab12",
            hookPhase: "PreToolUse", occurredAt: Date(), payloadJSON: #"{"tool":"Edit","args":{"file":"SleepManager.swift"}}"#,
            expiresAt: Date(timeIntervalSinceNow: 86400)
        )
        let redacted = Redactor.redact(event: event, minimal: true)
        XCTAssertEqual(redacted.payloadJSON, #"{"minimal":true}"#)
    }
}

// MARK: - CloudKit schema constants

final class CloudKitSchemaTests: XCTestCase {
    func testContainerIdentifier() {
        XCTAssertEqual(CloudKitSchema.containerIdentifier, "iCloud.com.doomcoder.app")
    }

    func testRecordTypeNames() {
        XCTAssertEqual(CloudKitSchema.RecordType.agentEvent, "AgentEvent")
        XCTAssertEqual(CloudKitSchema.RecordType.sessionAggregate, "SessionAggregate")
        XCTAssertEqual(CloudKitSchema.RecordType.approvalRequest, "ApprovalRequest")
        XCTAssertEqual(CloudKitSchema.RecordType.approvalResponse, "ApprovalResponse")
        XCTAssertEqual(CloudKitSchema.RecordType.devicePresence, "DevicePresence")
        XCTAssertEqual(CloudKitSchema.RecordType.userSettings, "UserSettings")
    }
}

// MARK: - AgentEvent record name

final class CKAgentEventTests: XCTestCase {
    func testRecordNameFormat() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000.5)
        let event = CKAgentEvent(
            sessionKey: "sess-abc", agent: "claude", agentVariant: nil,
            macHostname: "MacPro", cwdBasename: "myproject", cwdHashSuffix: "ff00",
            hookPhase: "PostToolUse", occurredAt: ts, payloadJSON: "{}",
            expiresAt: Date(timeIntervalSinceNow: 86400)
        )
        let name = event.recordName
        XCTAssertTrue(name.hasPrefix("sess-abc::PostToolUse::"), "record name should start with sessionKey::hookPhase::")
        XCTAssertTrue(name.contains("1700000000500"), "record name should embed millisecond timestamp")
    }
}

// MARK: - SessionAggregate status reducer

final class CKSessionAggregateTests: XCTestCase {
    func testInitialStatusIsRunning() {
        let now = Date()
        let agg = CKSessionAggregate(
            sessionKey: "s", agent: "claude", agentVariant: nil,
            macHostname: "Mac", cwdBasename: "proj", cwdHashSuffix: "00ff",
            startedAt: now, lastEventAt: now, endedAt: nil,
            status: .running, currentTool: nil,
            totalToolCalls: 0, totalFilesEdited: 0, totalErrors: 0,
            model: nil, promptPreview: nil,
            expiresAt: Date(timeIntervalSinceNow: 86400)
        )
        XCTAssertEqual(agg.status, .running)
        XCTAssertNil(agg.endedAt)
    }

    func testRecordNameIsSessionKey() {
        let agg = CKSessionAggregate(
            sessionKey: "unique-session-key", agent: "codex", agentVariant: nil,
            macHostname: "Mac", cwdBasename: "proj", cwdHashSuffix: "00ff",
            startedAt: Date(), lastEventAt: Date(), endedAt: nil,
            status: .running, currentTool: nil,
            totalToolCalls: 0, totalFilesEdited: 0, totalErrors: 0,
            model: nil, promptPreview: nil,
            expiresAt: Date(timeIntervalSinceNow: 86400)
        )
        XCTAssertEqual(agg.recordName, "unique-session-key")
    }
}

// MARK: - ApprovalRequest / ApprovalResponse

final class CKApprovalTests: XCTestCase {
    func testApprovalDecisions() {
        XCTAssertEqual(CKApprovalResponse.Decision.approve.rawValue, "approve")
        XCTAssertEqual(CKApprovalResponse.Decision.deny.rawValue, "deny")
        XCTAssertEqual(CKApprovalResponse.Decision.always.rawValue, "always")
    }

    func testRequestRecordNameIsRequestId() {
        let req = CKApprovalRequest(
            requestId: "req-xyz", sessionKey: "s", agent: "claude",
            toolName: "Bash", toolArgsJSON: #"{"command":"ls"}"#,
            requestedAt: Date(), expiresAt: Date(timeIntervalSinceNow: 60)
        )
        XCTAssertEqual(req.recordName, "req-xyz")
    }
}

// MARK: - DevicePresence platform

final class CKDevicePresenceTests: XCTestCase {
    func testPlatformRawValues() {
        XCTAssertEqual(CKDevicePresence.Platform.macOS.rawValue, "macOS")
        XCTAssertEqual(CKDevicePresence.Platform.iOS.rawValue, "iOS")
    }
}

// MARK: - HookEnvelope fixture tests (Gate G7 / dc-hook e2e)

final class HookEnvelopeFixtureTests: XCTestCase {

    private func envelope(
        agent: String,
        hookPhase: String,
        wantsBlockingReply: Bool = false,
        requestId: String? = nil,
        payload: [String: Any]? = nil,
        extraFields: [String: Any] = [:]
    ) -> Data {
        var obj: [String: Any] = [
            "v": "3",
            "schemaVersion": "3.0.0",
            "agent": agent,
            "event": hookPhase,
            "cwd": "/Users/dev/my-project",
            "pid": 12345,
            "ts": Date().timeIntervalSince1970,
            "synthetic": false,
            "macHostname": "TestMac",
            "cwdBasename": "my-project",
            "cwdHashSuffix": "ab12",
            "hookPhase": hookPhase,
            "wantsBlockingReply": wantsBlockingReply,
        ]
        if let rid = requestId { obj["requestId"] = rid }
        if let p = payload { obj["payload"] = p }
        for (k, v) in extraFields { obj[k] = v }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: Agent × phase coverage

    func testClaudeSessionStart() {
        let data = envelope(agent: "claude", hookPhase: "SessionStart")
        let env = HookEnvelope.decode(data)
        XCTAssertNotNil(env)
        XCTAssertEqual(env?.agent, "claude")
        XCTAssertEqual(env?.hookPhase, "SessionStart")
        XCTAssertFalse(env?.wantsBlockingReply ?? true)
    }

    func testClaudePreToolUse_blockingReply() {
        let data = envelope(agent: "claude", hookPhase: "PreToolUse",
                            wantsBlockingReply: true, requestId: "req-001",
                            payload: ["tool_name": "Bash", "tool_input": ["command": "rm -rf /"]])
        let env = HookEnvelope.decode(data)
        XCTAssertNotNil(env)
        XCTAssertTrue(env?.wantsBlockingReply ?? false)
        XCTAssertEqual(env?.requestId, "req-001")
        XCTAssertEqual(env?.payloadDict?["tool_name"] as? String, "Bash")
    }

    func testClaudePostToolUse() {
        let data = envelope(agent: "claude", hookPhase: "PostToolUse",
                            payload: ["tool_name": "Edit", "exit_code": 0])
        let env = HookEnvelope.decode(data)
        XCTAssertEqual(env?.hookPhase, "PostToolUse")
        XCTAssertEqual(env?.payloadDict?["exit_code"] as? Int, 0)
    }

    func testClaudeSessionStop() {
        let data = envelope(agent: "claude", hookPhase: "SessionStop",
                            payload: ["total_tool_calls": 17, "total_files_edited": 4])
        let env = HookEnvelope.decode(data)
        XCTAssertEqual(env?.hookPhase, "SessionStop")
        XCTAssertEqual(env?.payloadDict?["total_tool_calls"] as? Int, 17)
    }

    func testClaudeUserPromptSubmit() {
        let data = envelope(agent: "claude", hookPhase: "UserPromptSubmit",
                            payload: ["prompt_preview": "Help me refactor SleepManager"])
        let env = HookEnvelope.decode(data)
        XCTAssertEqual(env?.hookPhase, "UserPromptSubmit")
    }

    func testCursorPreToolUse() {
        let data = envelope(agent: "cursor", hookPhase: "PreToolUse",
                            payload: ["tool": "Read", "args": ["path": "src/main.ts"]])
        let env = HookEnvelope.decode(data)
        XCTAssertEqual(env?.agent, "cursor")
        XCTAssertEqual(env?.hookPhase, "PreToolUse")
    }

    func testCursorPostToolUse() {
        let data = envelope(agent: "cursor", hookPhase: "PostToolUse")
        let env = HookEnvelope.decode(data)
        XCTAssertEqual(env?.agent, "cursor")
        XCTAssertFalse(env?.wantsBlockingReply ?? true)
    }

    func testVSCodePreToolUse() {
        let data = envelope(agent: "vscode", hookPhase: "PreToolUse")
        let env = HookEnvelope.decode(data)
        XCTAssertEqual(env?.agent, "vscode")
    }

    func testCopilotCLIPreToolUse() {
        let data = envelope(agent: "copilot_cli", hookPhase: "PreToolUse")
        let env = HookEnvelope.decode(data)
        XCTAssertEqual(env?.agent, "copilot_cli")
    }

    func testWindsurfPreToolUse() {
        let data = envelope(agent: "windsurf", hookPhase: "PreToolUse")
        let env = HookEnvelope.decode(data)
        XCTAssertEqual(env?.agent, "windsurf")
    }

    func testCodexCLIPreToolUse() {
        let data = envelope(agent: "codex_cli", hookPhase: "PreToolUse")
        let env = HookEnvelope.decode(data)
        XCTAssertEqual(env?.agent, "codex_cli")
    }

    // MARK: Field defaults

    func testDefaultsWhenFieldsAbsent() {
        let minimal = """
        {"v":"3","agent":"claude","event":"SessionStart","ts":1700000000}
        """.data(using: .utf8)!
        let env = HookEnvelope.decode(minimal)
        XCTAssertNotNil(env)
        XCTAssertFalse(env?.wantsBlockingReply ?? true, "wantsBlockingReply defaults to false")
        XCTAssertNil(env?.requestId)
        XCTAssertNil(env?.hookPhase)
        XCTAssertNil(env?.macHostname)
        XCTAssertNil(env?.cwdBasename)
        XCTAssertEqual(env?.cwd, "")
    }

    func testSchemaVersionAndCwdFields() {
        let data = envelope(agent: "claude", hookPhase: "SessionStart")
        let env = HookEnvelope.decode(data)
        XCTAssertEqual(env?.schemaVersion, "3.0.0")
        XCTAssertEqual(env?.cwdBasename, "my-project")
        XCTAssertEqual(env?.cwdHashSuffix, "ab12")
        XCTAssertEqual(env?.macHostname, "TestMac")
    }

    // MARK: Malformed input

    func testMissingRequiredFieldReturnsNil() {
        let noAgent = """
        {"v":"3","event":"PreToolUse"}
        """.data(using: .utf8)!
        XCTAssertNil(HookEnvelope.decode(noAgent))
    }

    func testMissingVersionFieldReturnsNil() {
        let noV = """
        {"agent":"claude","event":"SessionStart"}
        """.data(using: .utf8)!
        XCTAssertNil(HookEnvelope.decode(noV))
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(HookEnvelope.decode(Data()))
    }

    func testNonJSONReturnsNil() {
        XCTAssertNil(HookEnvelope.decode("not json at all".data(using: .utf8)!))
    }

    func testArrayRootReturnsNil() {
        XCTAssertNil(HookEnvelope.decode("[1,2,3]".data(using: .utf8)!))
    }

    // MARK: Payload sub-object decoding

    func testPayloadDictAvailable() {
        let data = envelope(agent: "claude", hookPhase: "PostToolUse",
                            payload: ["tool": "Bash", "exit_code": 1, "duration_ms": 234])
        let env = HookEnvelope.decode(data)
        XCTAssertEqual(env?.payloadDict?["tool"] as? String, "Bash")
        XCTAssertEqual(env?.payloadDict?["exit_code"] as? Int, 1)
        XCTAssertEqual(env?.payloadDict?["duration_ms"] as? Int, 234)
    }

    func testMissingPayloadGivesNilDict() {
        let data = envelope(agent: "claude", hookPhase: "SessionStart")
        let env = HookEnvelope.decode(data)
        XCTAssertNil(env?.payloadDict)
    }
}

// MARK: - ApprovalCoordinator pure-logic tests

final class ApprovalCoordinatorPureTests: XCTestCase {

    private func makeEnvelope(
        agent: String = "claude",
        hostname: String? = "TestMac",
        cwdHashSuffix: String? = "ab12",
        cwd: String = "/Users/dev/project"
    ) -> HookEnvelope {
        HookEnvelope(
            v: "3", agent: agent, event: "PreToolUse",
            cwd: cwd, pid: 0, ts: Date().timeIntervalSince1970,
            synthetic: false, payloadRaw: nil,
            schemaVersion: "3.0.0", agentVariant: nil,
            macHostname: hostname, cwdBasename: nil,
            cwdHashSuffix: cwdHashSuffix, hookPhase: "PreToolUse",
            wantsBlockingReply: true, requestId: "req-test"
        )
    }

    func testDeriveSessionKeyUsesProvidedFields() {
        let env = makeEnvelope(agent: "claude", hostname: "Mac1", cwdHashSuffix: "ff00")
        let key = ApprovalCoordinator.deriveSessionKey(env: env)
        XCTAssertEqual(key, "Mac1::claude::ff00")
    }

    func testDeriveSessionKeyFallsBackToHostname() {
        let env = makeEnvelope(hostname: nil, cwdHashSuffix: "ab12")
        let key = ApprovalCoordinator.deriveSessionKey(env: env)
        XCTAssertTrue(key.hasSuffix("::claude::ab12"), "key should end in ::claude::ab12 got \(key)")
    }

    func testDeriveSessionKeyFallsBackToHashedCwd() {
        let env = makeEnvelope(hostname: "Mac2", cwdHashSuffix: nil, cwd: "/Users/dev/project")
        let key = ApprovalCoordinator.deriveSessionKey(env: env)
        XCTAssertTrue(key.hasPrefix("Mac2::claude::"), "key should start with Mac2::claude:: got \(key)")
        let suffix = key.components(separatedBy: "::").last ?? ""
        XCTAssertEqual(suffix.count, 6)
        XCTAssertTrue(suffix.allSatisfy({ $0.isHexDigit }), "suffix should be hex")
    }

    func testWriteDecisionFileCreatesFile() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doomcoder-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        ApprovalCoordinator.writeDecisionFile(requestId: "req-123", decision: "approve", in: tmpDir)

        let fileURL = tmpDir.appendingPathComponent("req-123.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let data = try Data(contentsOf: fileURL)
        let obj = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            "decision file should be valid JSON"
        )
        XCTAssertEqual(obj["decision"] as? String, "approve")
        XCTAssertNotNil(obj["ts"])
    }

    func testWriteDecisionFileDenyDecision() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doomcoder-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        ApprovalCoordinator.writeDecisionFile(requestId: "req-456", decision: "deny", in: tmpDir)

        let data = try Data(contentsOf: tmpDir.appendingPathComponent("req-456.json"))
        let obj = try XCTUnwrap((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
        XCTAssertEqual(obj["decision"] as? String, "deny")
    }

    func testWriteDecisionFileCreatesIntermediateDirectories() {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doomcoder-test-\(UUID().uuidString)")
            .appendingPathComponent("nested/deep/path")
        defer {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(tmpDir.pathComponents[tmpDir.pathComponents.count - 4])
            try? FileManager.default.removeItem(at: root)
        }

        ApprovalCoordinator.writeDecisionFile(requestId: "req-789", decision: "always", in: tmpDir)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmpDir.appendingPathComponent("req-789.json").path))
    }
}

// MARK: - NotificationPolicy pure-logic tests

final class NotificationPolicyTests: XCTestCase {
    func testTerminalEventsDetected() {
        XCTAssertTrue(NotificationPolicy.isTerminal(event: "sessionend"))
        XCTAssertTrue(NotificationPolicy.isTerminal(event: "SessionEnd"))
        XCTAssertTrue(NotificationPolicy.isTerminal(event: "sessionstop"))
        XCTAssertTrue(NotificationPolicy.isTerminal(event: "stop"))
        XCTAssertTrue(NotificationPolicy.isTerminal(event: "TaskCompleted"))
    }

    func testNonTerminalEventsNotDetected() {
        XCTAssertFalse(NotificationPolicy.isTerminal(event: "PreToolUse"))
        XCTAssertFalse(NotificationPolicy.isTerminal(event: "PostToolUse"))
        XCTAssertFalse(NotificationPolicy.isTerminal(event: "UserPromptSubmit"))
        XCTAssertFalse(NotificationPolicy.isTerminal(event: "SessionStart"))
    }
}

