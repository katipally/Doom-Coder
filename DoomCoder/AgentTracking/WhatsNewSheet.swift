import SwiftUI

// One-time "What's New in 1.9.0" sheet. Gated by a UserDefaults flag.
// Hosted in an NSWindow owned by the AppDelegate (MenuBarExtra can't host
// sheets). Call `onDismiss` to close the hosting window.
struct WhatsNewSheet: View {
    static let defaultsKey = "whats_new_v1_9_0_shown"

    var onDismiss: () -> Void = {}

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("What's new in DoomCoder 1.9.0", systemImage: "sparkles")
                .font(.title2.bold())

            featureRow(icon: "wrench.and.screwdriver", title: "Hooks done right",
                       body: "All four agent hook schemas are now correct — Claude, Cursor, VS Code Copilot, and Copilot CLI all fire reliably.")
            featureRow(icon: "arrow.triangle.2.circlepath", title: "Auto-migration",
                       body: "Broken v1.8.5 configs are detected and rewritten automatically with a backup.")
            featureRow(icon: "bell.badge", title: "Channel controls",
                       body: "Global channel defaults + per-agent overrides, with a test button for each channel.")
            featureRow(icon: "play.rectangle", title: "Demo sessions",
                       body: "Run a synthetic agent lifecycle to verify notifications without launching a real agent.")

            Divider()

            HStack {
                Button("Open Configure Agents") {
                    UserDefaults.standard.set(true, forKey: Self.defaultsKey)
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "configureAgents")
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Maybe later") {
                    UserDefaults.standard.set(true, forKey: Self.defaultsKey)
                    onDismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 440, alignment: .topLeading)
    }

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
}

