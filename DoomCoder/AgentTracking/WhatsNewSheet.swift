import SwiftUI

// One-time "What's New in v3.0" sheet, hosted in an NSWindow owned by the
// AppDelegate (MenuBarExtra can't host sheets). The 4 prior sheets
// (v1.9 / v2.0 / v2.2 / v2.3) were retired in v3.0 — this single sheet
// summarizes the iOS-companion overhaul that defines the v3.0 release.

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

// MARK: - v3.0.0 — iOS Companion overhaul

struct WhatsNewSheet300: View {
    static let defaultsKey = "whats_new_v3_0_0_shown"

    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("What's new in DoomCoder 3.0", systemImage: "sparkles")
                .font(.title2.bold())

            featureRow(
                icon: "iphone.gen3.radiowaves.left.and.right",
                title: "iPhone companion, properly redone",
                body: "Notifications on iPhone now match the Mac word-for-word. No more duplicate banners or 'Agent update' placeholder."
            )
            featureRow(
                icon: "icloud.fill",
                title: "Wake-on-LAN removed — iCloud handles it",
                body: "CloudKit silent push wakes a sleeping Mac on its own. No Wi-Fi gating, no MAC-address pairing, no 'open the app first'."
            )
            featureRow(
                icon: "arrow.triangle.2.circlepath",
                title: "Settings sync both ways",
                body: "Toggle a channel on iPhone — the Mac picks it up. Change a sleep mode on Mac — the iPhone updates. Per-field last-write-wins."
            )
            featureRow(
                icon: "slider.horizontal.3",
                title: "Mac panel mirrored on iPhone",
                body: "Master toggle, Prevent-Sleep modes, duration strip, agent activity grid — all of it on the phone."
            )
            featureRow(
                icon: "bolt.horizontal.fill",
                title: "Live Activity, widget, Siri",
                body: "Watch a session run from the Lock Screen. Pin DoomCoder to Home Screen or Control Center. Talk to Siri to keep your Mac awake."
            )

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
        .frame(width: 520, height: 480)
    }
}
