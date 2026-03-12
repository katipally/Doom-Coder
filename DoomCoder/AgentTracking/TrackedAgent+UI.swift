import SwiftUI

// MARK: - TrackedAgent UI metadata
//
// Centralizes the per-agent brand color that used to be a hardcoded `switch`
// buried inside LogsView. Keeping it on the enum means every Activity surface
// (sidebar dots, badges, the live indicator) derives color from one place, and
// adding a new `TrackedAgent` case forces the compiler to remind you to give it
// a color here — so a new agent shows up correctly with zero view edits.

extension TrackedAgent {
    /// Brand accent color for this agent. Used for badges, status dots, and the
    /// live indicator when no bundled icon is available.
    var brandColor: Color {
        switch self {
        case .claude:     return .orange
        case .cursor:     return .blue
        case .vscode:     return .purple
        case .copilotCLI: return .green
        case .windsurf:   return Color(red: 0, green: 0.67, blue: 1)
        case .codexCLI:   return Color(red: 0.4, green: 0.2, blue: 1.0)
        }
    }

    /// Color for a raw agent key string (e.g. from an event row). Falls back to
    /// gray for any key that isn't a known `TrackedAgent`.
    static func brandColor(forKey key: String) -> Color {
        TrackedAgent(rawValue: key)?.brandColor ?? .gray
    }
}
