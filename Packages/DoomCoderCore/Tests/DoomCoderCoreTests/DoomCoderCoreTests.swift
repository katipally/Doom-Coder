import Foundation
import Testing
@testable import DoomCoderCore

@Suite("SettingsRecord LWW merge")
struct SettingsMergeTests {

    @Test func newerWinsPerField() {
        var local = SettingsRecord()
        local.touch("masterEnabled", at: Date(timeIntervalSince1970: 100), by: "macA")
        local.masterEnabled = true
        local.touch("retentionDays", at: Date(timeIntervalSince1970: 200), by: "macA")
        local.retentionDays = 30

        var remote = SettingsRecord()
        remote.touch("masterEnabled", at: Date(timeIntervalSince1970: 150), by: "iOS")
        remote.masterEnabled = false
        remote.touch("retentionDays", at: Date(timeIntervalSince1970: 50), by: "iOS")
        remote.retentionDays = 1

        local.merge(with: remote)
        #expect(local.masterEnabled == false)   // remote.touch newer
        #expect(local.retentionDays == 30)      // local.touch newer
    }

    @Test func absentTimestampLosesToAny() {
        var local = SettingsRecord()
        local.touch("mode", at: Date(timeIntervalSince1970: 1), by: "macA")
        local.mode = "screenOff"

        var remote = SettingsRecord()
        remote.mode = "screenOn"   // no touch

        local.merge(with: remote)
        #expect(local.mode == "screenOff")
    }
}

@Suite("Notification copy parity")
struct NotificationCopyTests {

    @Test func sessionEndUsesDuration() {
        let ev = NotificationCopy.EventContext(
            agent: .claude, phase: .sessionEnd,
            lastTool: "Edit", cwdBase: "Doom-Coder",
            durationSeconds: 65
        )
        #expect(NotificationCopy.title(ev) == "Claude Code · done")
        #expect(NotificationCopy.body(ev) == "Finished using Edit · 1m 5s")
    }

    @Test func permissionNeededUsesTool() {
        let ev = NotificationCopy.EventContext(
            agent: .cursor, phase: .permissionNeeded, lastTool: "Shell"
        )
        #expect(NotificationCopy.title(ev) == "Cursor · needs you")
        #expect(NotificationCopy.body(ev) == "Waiting for your approval · Shell")
    }
}
