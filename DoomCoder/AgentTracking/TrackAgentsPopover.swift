import SwiftUI

// Inline accordion for the floating panel (PanelRootView).
//
// Shows only installed agents. Each row carries a live-session dot,
// a Tracking toggle, and — when Accessibility is granted — a blue badge
// on the icon when that agent's window is frontmost.
struct TrackAccordion: View {
    @State private var manager = AgentTrackingManager.shared
    @State private var enabled: [TrackedAgent: Bool] = [:]
    @State private var installed: [TrackedAgent: Bool] = [:]
    @State private var cliFolderCount: Int = 0
    @State private var tick = 0
    @State private var refreshTask: Task<Void, Never>? = nil

    var openConfigure: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            let configured = TrackedAgent.allCases.filter { installed[$0] == true }
            if configured.isEmpty {
                HStack(spacing: 8) {
                    Text("No agents configured.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Configure →", action: openConfigure)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                ForEach(configured, id: \.self) { agent in
                    compactRow(agent)
                }
            }
        }
        .onAppear {
            reload()
            refreshTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { break }
                    tick &+= 1
                    reload()
                }
            }
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .doomCoderIconsRefreshed)) { _ in
            reload()
        }
    }

    @ViewBuilder
    private func compactRow(_ agent: TrackedAgent) -> some View {
        let live = manager.liveSessions.first { $0.agent == agent }
        let isFrontmost = live?.isActiveWindow == true
        let agentSt = manager.agentState(for: agent)
        HStack(alignment: .center, spacing: 10) {
            // Agent icon with active-window badge overlay
            ZStack(alignment: .topTrailing) {
                Image(nsImage: AgentIconProvider.icon(for: agent, size: 20))
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                if isFrontmost {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName).font(.caption.weight(.medium))
                HStack(spacing: 4) {
                    Circle().fill(agentStateColor(agentSt)).frame(width: 6, height: 6)
                        .symbolEffect(.pulse, options: .repeating, isActive: agentSt == .working)
                    Text(subtitle(agent: agent, live: live, agentState: agentSt))
                        .font(.caption2).foregroundStyle(.secondary)
                        .contentTransition(.interpolate)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { enabled[agent] ?? true },
                set: { v in
                    withAnimation(DCAnim.snap) { enabled[agent] = v }
                    TrackingStore.setEnabled(agent, v)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard installed[agent] == true else { return }
            let v = !(enabled[agent] ?? true)
            withAnimation(DCAnim.snap) { enabled[agent] = v }
            TrackingStore.setEnabled(agent, v)
        }
        .transition(.opacity.combined(with: .offset(y: -8)))
    }

    private func subtitle(agent: TrackedAgent, live: AgentTrackingManager.Session?, agentState: AgentState) -> String {
        switch agentState {
        case .notInstalled: return "binary not found"
        case .installed:    return agent == .copilotCLI ? "\(cliFolderCount) folder\(cliFolderCount == 1 ? "" : "s")" : "not running"
        case .idle:         return live?.status ?? "idle"
        case .working:      return live?.status ?? "working…"
        case .closed:       return "closed"
        }
    }

    private func agentStateColor(_ s: AgentState) -> Color {
        switch s {
        case .notInstalled: return .secondary.opacity(0.25)
        case .installed:    return .secondary.opacity(0.55)
        case .idle:         return .green
        case .working:      return .yellow
        case .closed:       return .secondary.opacity(0.4)
        }
    }

    private func reload() {
        var eMap: [TrackedAgent: Bool] = [:]
        var iMap: [TrackedAgent: Bool] = [:]
        for a in TrackedAgent.allCases {
            eMap[a] = TrackingStore.isEnabled(a)
            iMap[a] = AgentInstallerV2.isInstalled(a)
        }
        withAnimation(DCAnim.smooth) {
            enabled = eMap
            installed = iMap
            cliFolderCount = CopilotCLIFolderManager.folderCount()
        }
    }

    // Count of installed agents (for header subtitle in parent view).
    static func configuredCount() -> Int {
        TrackedAgent.allCases.filter { AgentInstallerV2.isInstalled($0) }.count
    }
}
