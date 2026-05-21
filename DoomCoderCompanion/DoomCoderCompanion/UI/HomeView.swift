// HomeView.swift — DoomCoder Companion
// Primary dashboard: shows the primary Mac's live status, a PreventSleep
// control card, and an agent-activity grid. Wake-on-LAN was removed in
// v3.0 — CloudKit silent push wakes a sleeping Mac on its own.

import SwiftUI
import DoomCoderCore

struct HomeView: View {

    @State private var macStatus   = MacStatusStore.shared
    @State private var sessionStore = SessionStore.shared
    @State private var settings    = SettingsStore.shared
    @State private var sync        = CompanionSyncEngine.shared

    var body: some View {
        NavigationStack {
            Group {
                if shouldShowEmptyState {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle("DoomCoder")
        }
    }

    /// Show "No Mac" only after iCloud has positively reported "no Mac
    /// paired" — never on cold launch while the first fetch is still in
    /// flight. Prevents the false-positive that v3.0 users hit on every
    /// app open.
    private var shouldShowEmptyState: Bool {
        if !sync.accountAvailable { return true }
        if !macStatus.byMacId.isEmpty { return false }
        return sync.firstFetchCompleted
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView(
            sync.accountAvailable ? "No Mac Detected" : "iCloud Sign-In Required",
            systemImage: sync.accountAvailable
                ? "desktopcomputer.trianglebadge.exclamationmark"
                : "icloud.slash",
            description: Text(sync.accountAvailable
                ? "Sign in on your Mac with the same Apple Account to start syncing."
                : "Sign in to iCloud in Settings to pair this device with your Mac.")
        )
    }

    // MARK: - Main content

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !sync.firstFetchCompleted && macStatus.byMacId.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Syncing with iCloud…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                }
                if let mac = macStatus.primary {
                    MacStatusCard(mac: mac)
                }
                PreventSleepCard(settings: settings)
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
                .sensoryFeedback(.selection, trigger: settings.current.masterEnabled)
                .accessibilityHint("Turns DoomCoder on or off on your Mac.")

                Picker("Mode", selection: $localMode) {
                    Text("Screen On").tag(0)
                    Text("Screen Off").tag(1)
                }
                .pickerStyle(.segmented)
                .sensoryFeedback(.selection, trigger: localMode)
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
                    .sensoryFeedback(.selection, trigger: localHours)
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
