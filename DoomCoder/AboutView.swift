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

            Text("Keep your Mac awake. Nothing else.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            Text("A tiny menu bar utility that holds an IOPMAssertion to prevent macOS from sleeping. Pick Screen On to keep the display awake, or Screen Off to let the display sleep while the Mac stays running.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
}
