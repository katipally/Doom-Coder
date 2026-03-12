import Foundation
import Testing
@testable import DoomCodeCore

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

    @Test func sessionStartHasNoDuration() {
        let ev = NotificationCopy.EventContext(
            agent: .claude, phase: .sessionStart, lastTool: nil, cwdBase: nil
        )
        let body = NotificationCopy.body(ev)
        // No duration mentioned on a fresh start.
        #expect(!body.contains("·"))
    }

    @Test func completedUsesSessionEndCopy() {
        let ev = NotificationCopy.EventContext(
            agent: .codexCLI, phase: .sessionEnd, lastTool: nil
        )
        let title = NotificationCopy.title(ev)
        let body = NotificationCopy.body(ev)
        #expect(title == "Codex CLI · done")
        #expect(body.contains("Finished"))
    }

    @Test func errorMentionsFailure() {
        let ev = NotificationCopy.EventContext(
            agent: .windsurf, phase: .error
        )
        let title = NotificationCopy.title(ev)
        let body = NotificationCopy.body(ev)
        #expect(title.contains("error") || body.contains("error") || title.contains("ailed") || body.contains("ailed"))
    }

    @Test func subagentStartFallsBackToAgentName() {
        // The current body() implementation falls through to the
        // `default` case for .subagentStart, returning the agent's
        // display name. We document that behavior here so a future
        // refactor that adds subagent-specific copy will catch this
        // assertion as a forcing function.
        let ev = NotificationCopy.EventContext(
            agent: .claude, phase: .subagentStart, lastTool: "Plan"
        )
        let body = NotificationCopy.body(ev)
        #expect(body == "Claude Code")
    }
}
