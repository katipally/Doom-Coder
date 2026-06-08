import SwiftUI
import AppKit

// MARK: - AboutView
//
// About window for DoomCode. macOS 26 look: brand mark + app name +
// tagline, a Form (grouped style) for version/build/website, and inline
// links to GitHub, the App Store, and the privacy policy. The window
// is sized to the content and is the same liquid glass-tinted style
// as the rest of the app.
struct AboutView: View {
    private let version: String
    private let build: String

    private var appIcon: NSImage {
        if let named = NSImage(named: "AppIcon") { return named }
        return NSApplication.shared.applicationIconImage
    }

    init() {
        let info = Bundle.main.infoDictionary
        self.version = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        self.build = (info?["CFBundleVersion"] as? String) ?? "—"
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Doom Code")
                    .font(.largeTitle.bold())
                Text("Keep your Mac awake. Track your AI agents.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Form {
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
                LabeledContent("Website", value: "github.com/katipally/Doom-Code")
            }
            .formStyle(.grouped)
            .frame(width: 360)

            HStack(spacing: 16) {
                Link(destination: URL(string: "https://github.com/katipally/Doom-Code")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://apps.apple.com/app/doomcoder-companion/id6772514212")!) {
                    Label("Companion", systemImage: "iphone.gen3")
                }
                Link(destination: URL(string: "https://github.com/katipally/Doom-Code/blob/main/docs/privacy.md")!) {
                    Label("Privacy", systemImage: "hand.raised")
                }
            }
            .font(.subheadline)

            Text("© 2026 Doom Code. All rights reserved.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 460)
    }
}
