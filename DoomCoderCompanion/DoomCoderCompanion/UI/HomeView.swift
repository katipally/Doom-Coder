// HomeView.swift — DoomCoder Companion
// Primary dashboard: shows the primary Mac's live status, a PreventSleep
// control card, and an agent-activity grid. Wake-on-LAN was removed in
// v3.0 — CloudKit silent push wakes a sleeping Mac on its own.

import SwiftUI
import DoomCoderCore

struct HomeView: View {

    @State private var macStatus  = MacStatusStore.shared
    @State private var sessionStore = SessionStore.shared
    @State private var settings   = SettingsStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if macStatus.byMacId.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle("DoomCoder")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView(
            "No Mac Detected",
            systemImage: "desktopcomputer.trianglebadge.exclamationmark",
            description: Text("Open DoomCoder on your Mac first — the iPhone app will sync once it sees the Mac.")
        )
    }

    // MARK: - Main content

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let mac = macStatus.primary {
                    MacStatusCard(mac: mac)
                }
                PreventSleepCard(settings: settings)
                AgentsCard(sessionStore: sessionStore)
            }
            .padding()
        }
    }
}

// MARK: - MacStatusCard

private struct MacStatusCard: View {
    let mac: MacStatusRecord

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(mac.name, systemImage: "desktopcomputer")
                        .font(.headline)
                    Spacer()
                    statusPill
                }
                LabeledContent("Mode", value: mac.mode == "screenOn" ? "Screen On" : "Screen Off")
                if let ends = mac.sessionEndsAt {
                    LabeledContent("Session ends", value: ends, format: .relative(presentation: .numeric))
                }
                LabeledContent("Thermal", value: mac.thermalState)
                LabeledContent("Last seen", value: mac.lastSeen, format: .relative(presentation: .named))
            }
        } label: {
            Label("Mac Status", systemImage: "display")
        }
    }

    private var statusPill: some View {
        let asleep = mac.sleepActive
        return Text(asleep ? "Asleep" : "Awake")
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(asleep ? Color.secondary.opacity(0.2) : Color.green.opacity(0.2))
            .foregroundStyle(asleep ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
            .clipShape(Capsule())
    }
}

// MARK: - PreventSleepCard

private struct PreventSleepCard: View {
    var settings: SettingsStore
    @State private var localMode: Int = 0       // 0 = screenOn, 1 = screenOff
    @State private var localHours: Int = 0

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Master enabled", isOn: Binding(
                    get: { settings.current.masterEnabled },
                    set: { newVal in
                        settings.update(field: "masterEnabled") { $0.masterEnabled = newVal }
                        _ = sendToggleMaster()
                    }
                ))

                Picker("Mode", selection: $localMode) {
                    Text("Screen On").tag(0)
                    Text("Screen Off").tag(1)
                }
                .pickerStyle(.segmented)
                .onChange(of: localMode) { _, new in
                    let modeStr = new == 0 ? "screenOn" : "screenOff"
                    settings.update(field: "mode") { $0.mode = modeStr }
                    if let macId = MacStatusStore.shared.primary?.macId {
                        _ = CommandPublisher.shared.send(
                            verb: .setMode,
                            args: ["mode": modeStr],
                            targetMacId: macId
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Session timer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DurationStrip(selectedHours: localHours) { new in
                        localHours = new
                        settings.update(field: "sessionTimerHrs") { $0.sessionTimerHrs = new }
                        if let macId = MacStatusStore.shared.primary?.macId {
                            _ = CommandPublisher.shared.send(
                                verb: .setSessionTimer,
                                args: ["hours": "\(new)"],
                                targetMacId: macId
                            )
                        }
                    }
                }
            }
        } label: {
            Label("Prevent Sleep", systemImage: "moon.zzz.fill")
        }
        .onAppear {
            localMode  = settings.current.mode == "screenOn" ? 0 : 1
            localHours = settings.current.sessionTimerHrs
        }
        .onChange(of: settings.current.mode) { _, new in
            localMode = new == "screenOn" ? 0 : 1
        }
        .onChange(of: settings.current.sessionTimerHrs) { _, new in
            localHours = new
        }
    }

    private func sendToggleMaster() -> AsyncThrowingStream<CommandPublisher.Status, Error>? {
        guard let macId = MacStatusStore.shared.primary?.macId else { return nil }
        return CommandPublisher.shared.send(verb: .toggleMaster, targetMacId: macId)
    }
}

// MARK: - DurationStrip (∞ · 1h · 2h · 4h · 8h)

private struct DurationStrip: View {
    let selectedHours: Int
    var onSelect: (Int) -> Void

    private let options: [Int] = [0, 1, 2, 4, 8]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { h in
                let selected = selectedHours == h
                Button {
                    onSelect(h)
                } label: {
                    VStack(spacing: 4) {
                        Text(label(for: h))
                            .font(.caption.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                        Circle()
                            .fill(selected ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: 6, height: 6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: h))
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private func label(for h: Int) -> String {
        h == 0 ? "∞" : "\(h)h"
    }

    private func accessibilityLabel(for h: Int) -> String {
        h == 0 ? "Prevent sleep indefinitely" : "Prevent sleep for \(h) hour\(h == 1 ? "" : "s")"
    }
}

// MARK: - AgentsCard

private struct AgentsCard: View {
    var sessionStore: SessionStore

    var body: some View {
        GroupBox {
            VStack(spacing: 10) {
                // Live session rows surface above the agent grid so a
                // running session is the first thing the eye lands on.
                if !sessionStore.live.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(sessionStore.live, id: \.sessionKey) { s in
                            ActiveSessionRow(session: s)
                        }
                    }
                    Divider()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 8) {
                    ForEach(TrackedAgent.allCases, id: \.rawValue) { agent in
                        AgentTile(agent: agent, sessionStore: sessionStore)
                    }
                }
            }
        } label: {
            Label("Agents", systemImage: "cpu")
        }
    }
}

// MARK: - ActiveSessionRow

private struct ActiveSessionRow: View {
    let session: SessionRecord

    private var startedAgo: String {
        let interval = Date().timeIntervalSince(session.updatedAt)
        if interval < 60 { return "just now" }
        let m = Int(interval / 60)
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(Color.green).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.cwdDisplay)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(session.displayState)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(startedAgo)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private extension SessionRecord {
    /// Last path component of cwd; falls back to the whole string.
    var cwdDisplay: String {
        let path = cwd
        if path.isEmpty { return agent }
        return (path as NSString).lastPathComponent
    }
}

private struct AgentTile: View {
    let agent: TrackedAgent
    var sessionStore: SessionStore

    @State private var paused: Bool = false

    private var activeSession: SessionRecord? {
        sessionStore.live.first { $0.agent == agent.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(agent.displayName)
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(activeSession != nil ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
            }
            Text(activeSession?.displayState ?? "Idle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Per-agent pause / resume — fires the matching ControlCommand
            // verb, which the Mac router applies (sets a runtime gate so the
            // agent's hook events stop / start firing notifications).
            Button {
                togglePaused()
            } label: {
                Label(paused ? "Resume" : "Pause",
                      systemImage: paused ? "play.fill" : "pause.fill")
                    .font(.caption2.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func togglePaused() {
        guard let macId = MacStatusStore.shared.primary?.macId else { return }
        let next = !paused
        paused = next
        _ = CommandPublisher.shared.send(
            verb: next ? .pauseAgent : .resumeAgent,
            args: ["agent": agent.rawValue],
            targetMacId: macId
        )
    }
}

// MARK: - WakeCard removed in v3.0 (Wake-on-LAN deprecated).
