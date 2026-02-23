// DemoView.swift — DoomCoder Companion
// An interactive, clearly-labeled preview that works with NO Mac, NO iCloud and
// NO notifications. This demonstrates the app's real functionality on its own,
// which is what App Store Guideline 4.2.3(i) requires — a purely static
// explainer + download link is a known re-rejection pattern.
//
// Everything here is local sample data; nothing is written to CloudKit.

import SwiftUI
import DoomCoderCore

struct DemoView: View {
    @State private var showNotificationPreview = false

    // Demo Mac-control state (local only — never sends a command).
    @State private var demoMode: KeepAwakeMode = .auto
    @State private var demoScreen: ScreenMode = .screenOn
    @State private var demoTimer: Int = 2

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                banner

                section(title: "Sample agents", subtitle: "Tap one to see the activity timeline.") {
                    VStack(spacing: 0) {
                        ForEach(Array(Self.sampleAgents.enumerated()), id: \.offset) { idx, sample in
                            NavigationLink {
                                DemoAgentLogView(sample: sample)
                            } label: {
                                AgentRow(agent: sample.agent, status: sample.status, isInstalled: true)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            if idx < Self.sampleAgents.count - 1 {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                section(title: "Notifications", subtitle: "See how an agent alert looks on your device.") {
                    Button {
                        Haptics.tap()
                        showNotificationPreview = true
                    } label: {
                        Label("Preview a notification", systemImage: "bell.badge")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                }

                section(title: "Remote control", subtitle: "This is how you'll control your Mac's keep-awake state once connected.") {
                    MacControlCard(
                        macName: "Sample Mac",
                        lastSeen: nil,
                        isDemo: true,
                        mode: demoMode,
                        screen: demoScreen,
                        timerHours: demoTimer,
                        awakeActive: demoMode != .off,
                        activeAgentCount: 2,
                        elapsedSeconds: 1_530,
                        waiting: false,
                        onChangeMode: { demoMode = $0; Haptics.selection() },
                        onChangeScreen: { demoScreen = $0; Haptics.selection() },
                        onChangeTimer: { demoTimer = $0; Haptics.selection() }
                    )
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Demo")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showNotificationPreview) {
            NotificationPreviewSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Preview Mode")
                    .font(.headline)
                Text("Sample data shown below. Connect your Mac from the Home tab to see your real agents.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func section<Content: View>(title: String, subtitle: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.bold())
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sample data

    struct SampleAgent {
        let agent: TrackedAgent
        let status: String
        let logs: [NotificationLogRecord]
    }

    static let sampleAgents: [SampleAgent] = {
        let mac = "Sample Mac"
        func log(_ agent: TrackedAgent, _ phase: NormalizedEventPhase, _ title: String,
                 _ body: String, _ minutesAgo: Int, tool: String? = nil) -> NotificationLogRecord {
            NotificationLogRecord(
                sessionKey: "demo-\(agent.rawValue)", macId: "demo", macName: mac,
                agent: agent.rawValue, phase: phase.rawValue, rawEvent: "demo",
                title: title, body: body, channel: "iOS", success: true,
                ts: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo)), lastTool: tool)
        }
        return [
            SampleAgent(agent: .claude, status: "waiting for approval", logs: [
                log(.claude, .permissionNeeded, "Approval needed", "Claude wants to run `git push` — approve on your Mac.", 1),
                log(.claude, .toolEnd, "Edited 3 files", "Refactored the auth module.", 4, tool: "Edit"),
                log(.claude, .toolStart, "Running tests", "Started the unit test suite.", 6, tool: "Bash"),
                log(.claude, .sessionStart, "Session started", "Working in ~/Projects/api", 9)
            ]),
            SampleAgent(agent: .copilotCLI, status: "running", logs: [
                log(.copilotCLI, .toolStart, "Searching codebase", "Looking for the rate-limiter.", 0, tool: "Grep"),
                log(.copilotCLI, .agentResponse, "Drafted a plan", "Proposed a 3-step fix.", 2),
                log(.copilotCLI, .sessionStart, "Session started", "Working in ~/Projects/web", 5)
            ]),
            SampleAgent(agent: .codexCLI, status: "completed", logs: [
                log(.codexCLI, .sessionEnd, "Task complete", "All tests passing. 12 files changed.", 12),
                log(.codexCLI, .toolEnd, "Build succeeded", "Release build finished.", 14, tool: "Bash"),
                log(.codexCLI, .sessionStart, "Session started", "Working in ~/Projects/cli", 20)
            ])
        ]
    }()
}

// MARK: - Demo agent log screen

struct DemoAgentLogView: View {
    let sample: DemoView.SampleAgent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Activity")
                        .font(.headline)
                    Text("(\(sample.logs.count))")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 14)

                Divider()

                LazyVStack(spacing: 0) {
                    ForEach(sample.logs, id: \.notifId) { entry in
                        LogRow(log: entry).padding(.horizontal, 20)
                        Divider().padding(.leading, 20)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(sample.agent.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Notification preview

struct NotificationPreviewSheet: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("This is how an alert appears")
                .font(.headline)
                .padding(.top, 24)

            // A mock of the iOS notification banner.
            HStack(alignment: .top, spacing: 12) {
                Image("logo-square")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("DoomCoder").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("now").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Claude needs approval")
                        .font(.subheadline.weight(.medium))
                    Text("Wants to run `git push` in ~/Projects/api")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(14)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.horizontal, 20)
            .accessibilityElement(children: .combine)

            Text("Real notifications arrive when an agent on your connected Mac needs you. They're optional and contain no marketing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()
        }
    }
}
