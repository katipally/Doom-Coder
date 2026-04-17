import SwiftUI

/// First-run onboarding flow. Shown once, gated by
/// UserDefaults key `dc.onboardingCompleted`. Three pages:
///   1. Welcome + pick default Screen On / Screen Off mode.
///   2. Configure at least one agent (deep-link to Configure window).
///   3. Optional iPhone push channel.
struct OnboardingView: View {
    let sleepManager: SleepManager
    let onFinish: () -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var page: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcomePage.tag(0)
                agentsPage.tag(1)
                iphonePage.tag(2)
            }
            .tabViewStyle(.automatic)
            .frame(minHeight: 360)

            Divider()

            HStack {
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                Spacer()
                PageDots(current: page, total: 3)
                Spacer()
                if page < 2 {
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
        .frame(width: 560, height: 440)
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
