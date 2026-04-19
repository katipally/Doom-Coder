import SwiftUI

// Track Agents window (opened from menu bar).
//
// Goal: per-agent "send me updates about this agent" toggles. Same visual
// language as the Configure Agents list. Live session state shown inline.
//
// Flipping a toggle does not uninstall hooks — it only suppresses
// NotificationDispatcher from firing for that agent. Events still land in
// the event store and live-session UI.
struct TrackAgentsView: View {
    @State private var manager = AgentTrackingManager.shared
    @State private var pausedFlag: Bool = PauseFlag.isPaused
    @State private var enabled: [TrackedAgent: Bool] = [:]
    @State private var installed: [TrackedAgent: Bool] = [:]
    @State private var cliFolderCount: Int = 0
    @State private var tick = 0
    private let refreshTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(TrackedAgent.allCases, id: \.self) { agent in
                        row(agent)
                    }
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .frame(width: 420, height: 420)
        .onAppear { reload() }
        .onReceive(refreshTimer) { _ in tick &+= 1; reload() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(.secondary)
            Text("Track Agents").font(.headline)
            Spacer()
            Toggle("Paused", isOn: Binding(
                get: { pausedFlag },
                set: { on in PauseFlag.set(on); pausedFlag = on }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Button("Reveal logs") { NSWorkspace.shared.open(AgentLogDir.url) }
                .controlSize(.small)
            Spacer()
            Text("Toggle on to receive notifications for that agent.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func row(_ agent: TrackedAgent) -> some View {
        let live = manager.liveSessions.first { $0.agent == agent }
        let isInstalled = installed[agent] ?? false
        let isOn = enabled[agent] ?? true

        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: AgentIconProvider.icon(for: agent, size: 28))
                .resizable()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.displayName).font(.body.weight(.medium))
                    if !isInstalled {
                        Text("not installed")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(stateColor(live?.state))
                        .frame(width: 7, height: 7)
                    Text(subtitle(agent: agent, live: live))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { enabled[agent] ?? true },
                set: { v in
                    enabled[agent] = v
                    TrackingStore.setEnabled(agent, v)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(!isInstalled)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isOn && isInstalled ? Color.accentColor.opacity(0.06) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard isInstalled else { return }
            let v = !(enabled[agent] ?? true)
            enabled[agent] = v
            TrackingStore.setEnabled(agent, v)
        }
    }

    // MARK: - Helpers

    private func subtitle(agent: TrackedAgent, live: AgentTrackingManager.Session?) -> String {
        if let live { return live.state.humanReadable }
        if agent == .copilotCLI { return "\(cliFolderCount) folder\(cliFolderCount == 1 ? "" : "s")" }
        return "idle"
    }

    private func stateColor(_ s: AgentSessionState?) -> Color {
        guard let s else { return .secondary.opacity(0.5) }
        switch s {
        case .running:          return .green
        case .waitingInput:     return .yellow
        case .waitingApproval:  return .orange
        case .completed:        return .gray
        case .failed:           return .red
        }
    }

    private func reload() {
        var eMap: [TrackedAgent: Bool] = [:]
        var iMap: [TrackedAgent: Bool] = [:]
        for a in TrackedAgent.allCases {
            eMap[a] = TrackingStore.isEnabled(a)
            if a == .copilotCLI {
                iMap[a] = !CopilotCLIFolderManager.installedFolders().isEmpty
            } else {
                iMap[a] = AgentInstallerV2.isInstalled(a)
            }
        }
        enabled = eMap
        installed = iMap
        cliFolderCount = CopilotCLIFolderManager.folderCount()
        pausedFlag = PauseFlag.isPaused
    }
}
