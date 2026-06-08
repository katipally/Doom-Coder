import SwiftUI

// One-time "What's New" sheets, one struct per release, gated by UserDefaults.
// Hosted in an NSWindow owned by the AppDelegate (MenuBarExtra can't host sheets).

// Shared helper used by both WhatsNewSheetV2 and WhatsNewSheet.
@ViewBuilder
private func featureRow(icon: String, title: String, body: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
        Image(systemName: icon).font(.title3).frame(width: 28)
            .accessibilityHidden(true)
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
            Label("What's new in Doom Coder 2.0", systemImage: "sparkles")
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

// MARK: - v2.2.0 — Signed & notarized, bundled icons, privacy manifest

struct WhatsNewSheet220: View {
    static let defaultsKey = "whats_new_v2_2_0_shown"

    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("What's new in Doom Coder 2.2", systemImage: "sparkles")
                .font(.title2.bold())

            featureRow(icon: "checkmark.seal.fill", title: "Official signed & notarized app",
                       body: "Doom Coder is now signed with a Developer ID and notarized by Apple. No more Gatekeeper prompts — just double-click to install.")
            featureRow(icon: "photo.on.rectangle.angled", title: "Bundled agent icons",
                       body: "Claude, Codex, and Copilot CLI icons are built right into the app. They appear instantly in notifications and the menu, even without an internet connection.")
            featureRow(icon: "hand.raised.fill", title: "Privacy manifest",
                       body: "Doom Coder now ships a PrivacyInfo.xcprivacy declaring exactly which system APIs it uses. No data is collected or shared.")

            Divider()

            HStack {
                Spacer()
                Button("Got it") {
                    UserDefaults.standard.set(true, forKey: Self.defaultsKey)
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520, height: 420, alignment: .topLeading)
    }
}

// MARK: - v1.9.0 (legacy — keep for users who haven't seen it)

// One-time "What's New in 1.9.0" sheet. Gated by a UserDefaults flag.
// Hosted in an NSWindow owned by the AppDelegate (MenuBarExtra can't host
// sheets). Call `onDismiss` to close the hosting window.
struct WhatsNewSheet: View {
    static let defaultsKey = "whats_new_v1_9_0_shown"

    var onDismiss: () -> Void = {}

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("What's new in Doom Coder 1.9.0", systemImage: "sparkles")
                .font(.title2.bold())

            featureRow(icon: "wrench.and.screwdriver", title: "Hooks done right",
                       body: "All four agent hook schemas are now correct — Claude, Cursor, VS Code Copilot, and Copilot CLI all fire reliably.")
            featureRow(icon: "arrow.triangle.2.circlepath", title: "Auto-migration",
                       body: "Broken v1.8.5 configs are detected and rewritten automatically with a backup.")
            featureRow(icon: "bell.badge", title: "Smarter notifications",
                       body: "Pick exactly what each agent alerts you about, and no more auto-accept spam — permission alerts wait for proof a tool was really blocked.")
            featureRow(icon: "play.rectangle", title: "Demo sessions",
                       body: "Run a synthetic agent lifecycle to verify notifications without launching a real agent.")

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
                Button("Maybe later") {
                    UserDefaults.standard.set(true, forKey: Self.defaultsKey)
                    onDismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 440, alignment: .topLeading)
    }
}

// MARK: - v2.3.0 — Copilot CLI global hooks, all 13 events, VS Code split

struct WhatsNewSheet230: View {
    static let defaultsKey = "doomcoder.whatsnew.v2_3_0.seen"
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Copilot CLI, now first-class.").font(.title2.bold())
            }

            featureRow(
                icon: "globe",
                title: "Global Copilot CLI hooks",
                body: "Install once and Doom Coder tracks every `copilot` session in every directory. No more per-project folder list — hooks live at ~/.copilot/hooks/doomcoder.json."
            )
            featureRow(
                icon: "bell.badge",
                title: "All 13 events, including the per-turn notification",
                body: "We now wire every documented Copilot CLI hook event, including `notification` (agent_idle, agent_completed, shell_completed). You'll get the same 'agent done' alerts you get from Claude Code."
            )
            featureRow(
                icon: "rectangle.split.2x1",
                title: "VS Code Copilot moved to its own file",
                body: "VS Code Copilot Chat hooks now live at ~/.copilot/vscode-hooks/doomcoder.json. We patch chat.hookFilesLocations in every detected VS Code variant (Stable, Insiders, VSCodium, Cursor, Windsurf) automatically."
            )
            featureRow(
                icon: "bolt.heart",
                title: "Real running / idle indicator",
                body: "The main agents view now lights up green when `copilot` is running and dims when it's not — matching Claude Code and Codex CLI behavior."
            )

            Text("Migration is silent and one-shot. Per-project .github/hooks/doomcoder.json files are removed automatically. If you had committed one to git, you'll see it as a deletion in your next git status.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Got it") {
                    UserDefaults.standard.set(true, forKey: Self.defaultsKey)
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 460, alignment: .topLeading)
    }
}
