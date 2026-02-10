// SessionsView.swift — DoomCoder Companion (v3.1)
// Hosts the new "Agents" tab UI plus the per-session detail drill-down.
// File name preserved from v3.0 (Sessions tab) to avoid an Xcode project
// surgery; the public surface is `AgentsView` which RootTabView now wires
// in place of the retired SessionsView.

import SwiftUI
import UIKit
import DoomCoderCore

// MARK: - AgentIconLoader

/// Resolves a SwiftUI Image for a TrackedAgent. Bundle Asset catalog wins
/// (ships with the app, works on cold launch); the App Group icon cache —
/// populated by CloudKit AgentIcon push from the Mac — is a fallback for
/// agents added after this build shipped. SF Symbol is the last resort.
enum AgentIconLoader {

    static func bundleAssetName(for agent: TrackedAgent) -> String? {
        switch agent {
        case .claude:     return "agent-claude"
        case .cursor:     return "agent-cursor"
        case .windsurf:   return "agent-windsurf"
        case .codexCLI:   return "agent-codex"
        case .copilotCLI: return "agent-copilot-cli"
        case .vscode:     return nil
        }
    }

    static func sfSymbol(for agent: TrackedAgent) -> String {
        switch agent {
        case .claude:     return "c.circle.fill"
        case .cursor:     return "cursorarrow.rays"
        case .vscode:     return "chevron.left.forwardslash.chevron.right"
        case .copilotCLI: return "terminal.fill"
        case .windsurf:   return "wind"
        case .codexCLI:   return "circle.hexagongrid.fill"
        }
    }

    @ViewBuilder
    static func image(for agent: TrackedAgent, size: CGFloat = 28) -> some View {
        if let name = bundleAssetName(for: agent), UIImage(named: name) != nil {
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else if let url = AppGroupCache.iconURL(slug: agent.iconSlug),
                  let data = try? Data(contentsOf: url),
                  let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            Image(systemName: sfSymbol(for: agent))
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - PerAgentOverrides codec

/// Wire format: `{"claude":{"mac":true,"ios":true,"tracking":true}, ...}`.
/// `tracking` is the global enable/disable gate (mirrors Mac TrackingStore).
/// `mac`/`ios` are the per-channel routing flags (mirrors Mac ChannelStore).
/// We keep all three in lock-step on every iOS write so both old and new
/// Mac builds see the user's intent correctly.
enum PerAgentOverrides {

    static func isEnabled(_ agent: TrackedAgent, in json: String) -> Bool {
        guard
            let data = json.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Bool]]
        else { return true }
        if let entry = dict[agent.rawValue] {
            // `tracking` is the primary flag (controls Mac TrackingStore + iOS display).
            // Fall back to mac && ios AND-gate for records from builds before v3.1.
            if let tracking = entry["tracking"] { return tracking }
            return (entry["mac"] ?? true) && (entry["ios"] ?? true)
        }
        return true
    }

    static func setting(_ agent: TrackedAgent, enabled: Bool, in json: String) -> String {
        var dict: [String: [String: Bool]] = {
            guard
                let data = json.data(using: .utf8),
                let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Bool]]
            else { return [:] }
            return parsed
        }()
        var entry = dict[agent.rawValue] ?? [:]
        entry["mac"]      = enabled
        entry["ios"]      = enabled
        entry["tracking"] = enabled
        dict[agent.rawValue] = entry
        guard let out = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: out, encoding: .utf8) else {
            return json
        }
        return str
    }

    /// v3.2 — sub-keys stamped together when iOS toggles an agent.
    /// Used by SettingsStore to call SettingsRecord.touchPerAgent so the
    /// per-agent LWW merge picks the right side per (agent, sub-key).
    static let toggleSubKeys = ["mac", "ios", "tracking"]

    /// Returns the list of agents the Mac has actually configured (hooks
    /// installed). The iOS Agents tab only shows these — agents the user
    /// hasn't set up on the Mac never appear in the companion list.
    static func configuredAgents(in json: String) -> [TrackedAgent] {
        guard
            let data = json.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Bool]]
        else { return [] }
        return TrackedAgent.allCases.filter { agent in
            // `installed` key written by Mac. If absent, treat as not configured
            // (was never published) so we hide the row rather than show a stub.
            dict[agent.rawValue]?["installed"] == true
        }
    }
}

// MARK: - Agent status (derived, no new CloudKit data)

enum AgentStatus {
    case disabled, active, waiting, idle

    var label: String {
        switch self {
        case .disabled: return "Off"
        case .active:   return "Active"
        case .waiting:  return "Needs you"
        case .idle:     return "Idle"
        }
    }

    var tint: Color {
        switch self {
        case .disabled: return .secondary
        case .active:   return .green
        case .waiting:  return .orange
        case .idle:     return .secondary
        }
    }
}

@MainActor
private func currentStatus(for agent: TrackedAgent,
                           settings: SettingsRecord,
                           sessions: [SessionRecord]) -> AgentStatus {
    if PerAgentOverrides.isEnabled(agent, in: settings.perAgentOverridesJSON) == false {
        return .disabled
    }
    let live = sessions.first { $0.agent == agent.rawValue }
    if let s = live {
        return s.awaitingPermission ? .waiting : .active
    }
    return .idle
}

// MARK: - AgentsView

struct AgentsView: View {

    @State private var sessionStore = SessionStore.shared
    @State private var settings     = SettingsStore.shared
    @State private var navPath      = NavigationPath()

    /// Deeplink from Live Activity or `doomcoder://session/<key>` URL.
    @Binding var deeplinkSessionKey: String?

    init(deeplinkSessionKey: Binding<String?> = .constant(nil)) {
        self._deeplinkSessionKey = deeplinkSessionKey
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            let configured = PerAgentOverrides.configuredAgents(in: settings.current.perAgentOverridesJSON)
            List {
                if !sessionStore.live.isEmpty {
                    Section("Live") {
                        ForEach(sessionStore.live, id: \.sessionKey) { s in
                            NavigationLink(value: s) {
                                LiveSessionRow(session: s)
                            }
                        }
                    }
                }
                if configured.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No agents configured")
                                .font(.callout.weight(.medium))
                            Text("Open DoomCoder on your Mac and configure at least one agent. It will appear here automatically.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    Section("Configured") {
                        ForEach(configured, id: \.rawValue) { agent in
                            NavigationLink(value: agent) {
                                AgentRow(agent: agent,
                                         settings: settings,
                                         sessionStore: sessionStore)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Agents")
            .refreshable { await CompanionSyncEngine.shared.fetchChanges() }
            .navigationDestination(for: TrackedAgent.self) { agent in
                AgentDetailView(agent: agent)
            }
            .navigationDestination(for: SessionRecord.self) { session in
                SessionDetailView(session: session)
            }
        }
        .onChange(of: deeplinkSessionKey) { _, key in
            guard let key else { return }
            if let session = sessionStore.live.first(where: { $0.sessionKey == key }) {
                navPath.append(session)
            }
            deeplinkSessionKey = nil
        }
        .task {
            // One-shot warm fetch on appear. Push delivery + pull-to-refresh
            // are the steady-state paths; the 30 s polling loop was removed
            // in v3.2 (battery drain on a tab the user often leaves open).
            await CompanionSyncEngine.shared.fetchChanges()
        }
    }
}

// MARK: - LiveSessionRow

private struct LiveSessionRow: View {
    let session: SessionRecord

    private var agent: TrackedAgent? { TrackedAgent(rawValue: session.agent) }

    var body: some View {
        HStack(spacing: 12) {
            if let agent { AgentIconLoader.image(for: agent, size: 32) }
            VStack(alignment: .leading, spacing: 2) {
                Text(agent?.displayName ?? session.agent).font(.headline)
                if let base = session.cwdBase, !base.isEmpty {
                    Text(base).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(session.displayState).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if session.awaitingPermission {
                Label("Needs you", systemImage: "hand.raised.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - AgentRow

private struct AgentRow: View {
    let agent: TrackedAgent
    var settings: SettingsStore
    var sessionStore: SessionStore

    private var status: AgentStatus {
        currentStatus(for: agent,
                      settings: settings.current,
                      sessions: sessionStore.live)
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { PerAgentOverrides.isEnabled(agent, in: settings.current.perAgentOverridesJSON) },
            set: { newVal in
                let next = PerAgentOverrides.setting(agent,
                                                     enabled: newVal,
                                                     in: settings.current.perAgentOverridesJSON)
                settings.updatePerAgent(agent: agent.rawValue,
                                        subs: PerAgentOverrides.toggleSubKeys) {
                    $0.perAgentOverridesJSON = next
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            AgentIconLoader.image(for: agent, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName).font(.body)
                StatusPill(status: status)
            }
            Spacer()
            Toggle("", isOn: isEnabled)
                .labelsHidden()
                .accessibilityLabel("Enable \(agent.displayName)")
        }
        .padding(.vertical, 4)
    }
}

private struct StatusPill: View {
    let status: AgentStatus
    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(status.tint.opacity(0.18))
            .foregroundStyle(status.tint)
            .clipShape(Capsule())
    }
}

// MARK: - AgentDetailView

struct AgentDetailView: View {

    let agent: TrackedAgent
    @State private var settings     = SettingsStore.shared
    @State private var sessionStore = SessionStore.shared
    @State private var notifStore   = NotificationLogStore.shared

    private var status: AgentStatus {
        currentStatus(for: agent,
                      settings: settings.current,
                      sessions: sessionStore.live)
    }

    private var entries: [NotificationLogRecord] {
        notifStore.entries.filter { $0.agent == agent.rawValue }
    }

    private var liveForAgent: [SessionRecord] {
        sessionStore.live.filter { $0.agent == agent.rawValue }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { PerAgentOverrides.isEnabled(agent, in: settings.current.perAgentOverridesJSON) },
            set: { newVal in
                let next = PerAgentOverrides.setting(agent,
                                                     enabled: newVal,
                                                     in: settings.current.perAgentOverridesJSON)
                settings.updatePerAgent(agent: agent.rawValue,
                                        subs: PerAgentOverrides.toggleSubKeys) {
                    $0.perAgentOverridesJSON = next
                }
            }
        )
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AgentIconLoader.image(for: agent, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.displayName).font(.title3.weight(.semibold))
                        StatusPill(status: status)
                    }
                }
                Toggle("Notifications enabled", isOn: enabledBinding)
            }

            if !liveForAgent.isEmpty {
                Section("Live sessions") {
                    ForEach(liveForAgent, id: \.sessionKey) { s in
                        NavigationLink(value: s) {
                            LiveSessionRow(session: s)
                        }
                    }
                }
            }

            Section("History (\(entries.count))") {
                if entries.isEmpty {
                    Text("No events recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries, id: \.notifId) { entry in
                        EventRow(entry: entry)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(agent.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - SessionDetailView (moved from retired SessionsView body)

struct SessionDetailView: View {

    let session: SessionRecord

    @State private var notifStore = NotificationLogStore.shared

    private var relatedEntries: [NotificationLogRecord] {
        notifStore.entries.filter { $0.sessionKey == session.sessionKey }
    }

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("Agent",
                               value: TrackedAgent(rawValue: session.agent)?.displayName ?? session.agent)
                LabeledContent("State", value: session.displayState)
                if let base = session.cwdBase {
                    LabeledContent("Directory", value: base)
                }
                LabeledContent("Started", value: session.startedAt, format: .dateTime)
                LabeledContent("Tools", value: "\(session.toolCallCount)")
                LabeledContent("Errors", value: "\(session.errorCount)")
                if session.awaitingPermission {
                    Label("Awaiting your permission", systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("Timeline (\(relatedEntries.count))") {
                if relatedEntries.isEmpty {
                    Text("No events synced yet").foregroundStyle(.secondary)
                } else {
                    ForEach(relatedEntries, id: \.notifId) { entry in
                        EventRow(entry: entry)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(session.cwdBase ?? session.agent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await CompanionSyncEngine.shared.fetchChanges()
        }
    }
}

// MARK: - EventRow (shared)

private struct EventRow: View {
    let entry: NotificationLogRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                phaseLabel
                Spacer()
                Text(entry.ts, style: .time).font(.caption2).foregroundStyle(.tertiary)
            }
            if !entry.title.isEmpty {
                Text(entry.title).font(.caption.weight(.semibold))
            }
            if !entry.body.isEmpty {
                Text(entry.body).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var phaseLabel: some View {
        let phase = NormalizedEventPhase(rawValue: entry.phase) ?? .other
        let color: Color = {
            switch phase {
            case .error, .toolError: return .red
            case .permissionNeeded:  return .orange
            case .sessionEnd:        return .green
            case .sessionStart:      return .blue
            default:                 return .secondary
            }
        }()
        return Text(entry.phase)
            .font(.caption.bold())
            .foregroundStyle(color)
    }
}
