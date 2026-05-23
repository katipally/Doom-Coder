import Foundation
import Testing
@testable import DoomCoderCore

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
