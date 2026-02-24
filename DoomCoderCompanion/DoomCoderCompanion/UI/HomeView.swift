// HomeView.swift — DoomCoder Companion
// The standalone home hub. Fully usable with no Mac / iCloud / notifications:
// it explains the product, offers an interactive demo, and (when connected)
// surfaces the live "Your Mac" remote-control card. This is the centerpiece of
// the App Store 4.2.3 standalone-functionality fix.

import SwiftUI
import DoomCoderCore

struct HomeView: View {
    @State private var macStore = MacStatusStore.shared
    @State private var showConnect = false

    private let downloadURL = URL(string: "https://github.com/katipally/Doom-Coder/releases")!

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                MacReachabilityBanner()
                connectionSection
                whatIsSection
                keepAwakeGuide
                howItWorks
                faqSection
                downloadSection
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("DoomCoder")
        .refreshable {
            await CompanionSyncEngine.shared.fetchChanges()
        }
        .sheet(isPresented: $showConnect) {
            ConnectFlowView(onFinished: {})
        }
    }

    // MARK: - 1. Connection / Your Mac

    @ViewBuilder
    private var connectionSection: some View {
        if macStore.primary != nil {
            MacControlView()
        } else {
            VStack(spacing: 16) {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("Connect your Mac")
                        .font(.title3.bold())
                    Text("Pair with the DoomCoder Mac app to see live agents and control keep-awake from here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Haptics.tap()
                    showConnect = true
                } label: {
                    Label("Connect", systemImage: "link")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                NavigationLink {
                    DemoView()
                } label: {
                    Label("Try the interactive demo", systemImage: "play.circle")
                        .font(.subheadline.weight(.medium))
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: - 2. What is DoomCoder?

    private var whatIsSection: some View {
        InfoCard(title: "What is DoomCoder?", systemImage: "questionmark.circle") {
            Text("DoomCoder watches the AI coding agents running on your Mac — Claude Code, Copilot, Codex and more — and keeps your Mac awake so long tasks don't get interrupted.")
            Text("This companion app brings that to your iPhone and iPad: live status, attention alerts, and remote keep-awake control.")
        }
    }

    // MARK: - 3. Keep Mac awake guide

    private var keepAwakeGuide: some View {
        InfoCard(title: "Keep your Mac awake", systemImage: "powersleep") {
            GuideRow(symbol: "powersleep", title: "Off",
                     detail: "Your Mac follows its normal sleep settings.")
            GuideRow(symbol: "cup.and.saucer.fill", title: "On",
                     detail: "Stays awake until you turn it off or the auto-off timer fires.")
            GuideRow(symbol: "sparkles", title: "Auto",
                     detail: "Stays awake only while an agent is actively working, then sleeps shortly after it finishes.")
            Text("You can also choose whether to keep the screen on or let it switch off while staying awake.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 4. How it works

    private var howItWorks: some View {
        InfoCard(title: "How it works", systemImage: "list.number") {
            StepRow(number: 1, text: "Install DoomCoder on your Mac and sign in to iCloud.")
            StepRow(number: 2, text: "Open this app and tap Connect to find your Mac.")
            StepRow(number: 3, text: "Enable notifications to get attention alerts (optional).")
        }
    }

    // MARK: - 5. FAQ

    private var faqSection: some View {
        InfoCard(title: "FAQ", systemImage: "text.bubble") {
            FAQRow(q: "Do I need the Mac app?",
                   a: "You can explore everything here, including the demo. Live agent data and remote control require the free DoomCoder Mac app.")
            FAQRow(q: "Is my data private?",
                   a: "Everything syncs through your own private iCloud. There are no accounts and no servers we operate.")
            FAQRow(q: "Are notifications required?",
                   a: "No. They're optional and only used to tell you when an agent needs your attention.")
            FAQRow(q: "Why won't my command apply instantly?",
                   a: "iCloud can't wake a sleeping Mac. Commands apply the next time your Mac is awake and checks in.")
        }
    }

    // MARK: - 6. Download

    private var downloadSection: some View {
        Link(destination: downloadURL) {
            Label("Download DoomCoder for Mac", systemImage: "arrow.down.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

// MARK: - Building blocks

private struct InfoCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct GuideRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 26)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(.tint)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FAQRow: View {
    let q: String
    let a: String

    var body: some View {
        DisclosureGroup {
            Text(a)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        } label: {
            Text(q).font(.subheadline.weight(.medium))
        }
    }
}
