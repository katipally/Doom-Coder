// WelcomeView.swift — DoomCoder Companion
// First-run informational sheet. Purely explanatory and dismissible — it never
// blocks the app. Sets expectations: the app works on its own, and connecting a
// Mac unlocks live agent monitoring + remote keep-awake control.

import SwiftUI

struct WelcomeView: View {
    static let shownKey = "welcome.shownAt"

    let onDismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image("logo-square")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("Welcome to DoomCoder")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Companion")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 18) {
                    FeatureRow(symbol: "bell.badge",
                               title: "Stay in the loop",
                               detail: "Get a notification when an AI agent on your Mac needs your attention.")
                    FeatureRow(symbol: "powersleep",
                               title: "Keep your Mac awake",
                               detail: "Stop long agent runs from being interrupted by sleep — control it from your pocket.")
                    FeatureRow(symbol: "macbook.and.iphone",
                               title: "Better together",
                               detail: "DoomCoder is a companion to the DoomCoder Mac app. You can explore everything here first — connect a Mac when you're ready for live data.")
                }
                .padding(.horizontal, 4)

                Button(action: onDismiss) {
                    Text("Get Started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)

                Text("No account needed. Notifications are optional.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .presentationDragIndicator(.visible)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
