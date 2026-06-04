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
                    FeatureRow(symbol: "wrench.and.screwdriver",
                               title: "A toolkit for AI coding",
                               detail: "A prompt composer, a curated prompt library, and smart notes with reminders — all on your device, no Mac or account needed.")
                    FeatureRow(symbol: "sparkles",
                               title: "Better prompts, instantly",
                               detail: "Turn a rough idea into a well-structured prompt to paste into Claude Code, Codex, Copilot and more.")
                     FeatureRow(symbol: "macbook.and.iphone",
                                title: "Connect your Mac (optional)",
                                detail: "Add the free DoomCoder Mac app to monitor live agents and receive their notifications on the Dashboard tab. Pairing works automatically when you share an Apple ID, or via a one-time QR code if you don't.")
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
