import SwiftUI

/// First-run onboarding flow. Shown once, gated by
/// UserDefaults key `dc.onboardingCompleted`. Four pages:
///   1. How DoomCoder works — 20-second explainer + Mac↔Socket↔Agent diagram.
///   2. Welcome + pick default Screen On / Screen Off mode.
///   3. Configure at least one agent (deep-link to Configure window).
///   4. Optional iPhone push channel.
struct OnboardingView: View {
    let sleepManager: SleepManager
    let onFinish: () -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var page: Int = 0

    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                howItWorksPage.tag(0)
                welcomePage.tag(1)
                agentsPage.tag(2)
                iphonePage.tag(3)
            }
            .tabViewStyle(.automatic)
            .frame(minHeight: 360)

            Divider()

            HStack {
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                Spacer()
                PageDots(current: page, total: pageCount)
                Spacer()
                if page < pageCount - 1 {
                    Button("Next") { page += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Finish") {
                        UserDefaults.standard.set(true, forKey: "dc.onboardingCompleted")
                        onFinish()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 460)
    }

    // MARK: Page 0 — How it works

    private var howItWorksPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 42)).foregroundStyle(.tint)
            Text("How DoomCoder works").font(.largeTitle.bold())
            Text("A 20-second tour so nothing feels like magic.")
                .foregroundStyle(.secondary)

            flowDiagram
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 10) {
                bullet(icon: "1.circle.fill",
                       title: "Your AI agent calls `dc`",
                       body: "A tiny built-in tool we install into each supported agent. It reports start, waiting, error, and done.")
                bullet(icon: "2.circle.fill",
                       title: "DoomCoder keeps your Mac alive",
                       body: "Sleep + App Nap stay disabled while any session is live, in Screen On or Screen Off mode.")
                bullet(icon: "3.circle.fill",
                       title: "You get notified when it matters",
                       body: "Mac banners plus optional iPhone pushes via ntfy. Pick per-agent what you want to track.")
            }
        }
        .padding(32)
    }

    private var flowDiagram: some View {
        HStack(spacing: 10) {
            diagramBox(icon: "desktopcomputer", label: "Mac")
            diagramArrow
            diagramBox(icon: "app.connected.to.app.below.fill", label: "Socket")
            diagramArrow
            diagramBox(icon: "brain", label: "Agent")
        }
        .frame(maxWidth: .infinity)
    }

    private func diagramBox(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 80, height: 60)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        }
    }

    private var diagramArrow: some View {
        Image(systemName: "arrow.left.and.right")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    private func bullet(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.semibold)
                Text(body).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 42)).foregroundStyle(.tint)
            Text("Welcome to DoomCoder").font(.largeTitle.bold())
            Text("Keep your Mac alive while AI agents do the work. Pick how you want it to behave by default — you can change this any time from the menubar.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(DoomCoderMode.allCases, id: \.self) { mode in
                    Button {
                        sleepManager.mode = mode
                    } label: {
                        HStack {
                            Image(systemName: sleepManager.mode == mode ? "largecircle.fill.circle" : "circle")
                            VStack(alignment: .leading) {
                                Text(mode.displayName).font(.headline)
                                Text(mode == .screenOn
                                     ? "Display stays on. Mac awake."
                                     : "Display sleeps, Mac stays awake — touch input wakes screen.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(sleepManager.mode == mode ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(32)
    }

    private var agentsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 42)).foregroundStyle(.tint)
            Text("Configure an AI agent").font(.largeTitle.bold())
            Text("Pick at least one AI agent — Cursor, Claude Code, Copilot CLI, Windsurf, VS Code MCP, Gemini, or Codex — and run its guided Setup. DoomCoder wires a local MCP server so the agent can announce start, wait, error, and done events to you.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openWindow(id: "configure")
            } label: {
                Label("Open Configure Agents", systemImage: "gearshape.2")
            }
            .buttonStyle(.borderedProminent)

            Text("Already configured? Skip to the next page.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(32)
    }

    private var iphonePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "iphone")
                .font(.system(size: 42)).foregroundStyle(.tint)
            Text("iPhone notifications (optional)").font(.largeTitle.bold())
            Text("Get notified on your phone when an agent needs you — via ntfy.sh, a lightweight push channel. This is optional; Mac notifications always work out of the box.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openWindow(id: "settings")
            } label: {
                Label("Open Settings", systemImage: "gearshape")
            }
        }
        .padding(32)
    }
}

private struct PageDots: View {
    let current: Int
    let total: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Circle()
                    .fill(i == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }
}
