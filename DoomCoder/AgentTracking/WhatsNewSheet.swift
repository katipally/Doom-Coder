import SwiftUI

// One-time "What's New" sheets, one struct per release, gated by UserDefaults.
// Hosted in an NSWindow owned by the AppDelegate (MenuBarExtra can't host sheets).

// Shared helper used by both WhatsNewSheetV2 and WhatsNewSheet.
@ViewBuilder
private func featureRow(icon: String, title: String, body: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
        Image(systemName: icon).font(.title3).frame(width: 28)
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(body).foregroundStyle(.secondary).font(.callout)
        }
    }
}

// MARK: - v2.0.0 — Windsurf, notification polish, false-positive fix

struct WhatsNewSheetV2: View {
    static let defaultsKey = "whats_new_v2_0_0_shown"

    var onDismiss: () -> Void = {}

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("What's new in DoomCoder 2.0", systemImage: "sparkles")
                .font(.title2.bold())

            featureRow(icon: "wind", title: "Windsurf support",
                       body: "All 12 Windsurf Cascade hooks are now tracked — done, errors, tool activity, MCP, and more.")
            featureRow(icon: "bell.badge.fill", title: "Smarter notifications",
                       body: "Done and error notifications now include session duration. Waiting detection added for Cursor, VS Code, and Windsurf.")
            featureRow(icon: "app.badge.checkmark", title: "Agent icons in notifications",
                       body: "Each notification shows the real app icon so you instantly know which tool finished.")
            featureRow(icon: "checkmark.shield", title: "False positive fix",
                       body: "Claude Code inside Cursor or VS Code terminal now correctly shows as Claude Code, not VS Code Copilot.")

            Divider()

            HStack {
                Button("Open Configure Agents") {
                    UserDefaults.standard.set(true, forKey: Self.defaultsKey)
                    NSApp.activate()
                    openWindow(id: "configureAgents")
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Got it") {
                    UserDefaults.standard.set(true, forKey: Self.defaultsKey)
                    onDismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 460, alignment: .topLeading)
    }
}



