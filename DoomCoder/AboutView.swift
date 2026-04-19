import SwiftUI

struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            Text("Doom Coder")
                .font(.title.bold())

            Text("Version \(version)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Keep your Mac awake. Track your AI agents.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            Text("A lightweight menu bar utility that prevents macOS from sleeping and tracks AI agent sessions. Pick Screen On or Screen Off for sleep blocking, and configure hooks for Claude Code, Cursor, VS Code Copilot, and Copilot CLI to get real-time notifications.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
}
