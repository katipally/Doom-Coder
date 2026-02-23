// MacControlView.swift — DoomCoder Companion
// The "Your Mac" remote-control card. Lets the user drive the Mac's keep-awake
// state (Off / On / Auto), screen behaviour, and auto-off timer from iOS.
//
// Writer path: each change issues a ControlCommandRecord (see CompanionSyncEngine
// .sendControlCommand). The Mac applies it on its next fetch and acks via
// MacStatusRecord.lastAppliedCommandId — we reconcile optimistic UI against that.
// CloudKit cannot wake a sleeping Mac, so copy never implies the change is
// instant; we show "waiting for your Mac to check in" until the ack lands.

import SwiftUI
import DoomCoderCore

/// Auto-off timer choices (hours; 0 = never).
private let timerChoices: [Int] = [0, 1, 2, 4, 8]
private func timerLabel(_ h: Int) -> String { h == 0 ? "Never" : "\(h)h" }

// MARK: - Presentational card (shared by live + demo)

struct MacControlCard: View {
    let macName: String
    let lastSeen: Date?
    let isDemo: Bool

    let mode: KeepAwakeMode
    let screen: ScreenMode
    let timerHours: Int

    let awakeActive: Bool
    let activeAgentCount: Int
    let waiting: Bool

    var onChangeMode: (KeepAwakeMode) -> Void
    var onChangeScreen: (ScreenMode) -> Void
    var onChangeTimer: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            // Keep Awake mode
            VStack(alignment: .leading, spacing: 8) {
                Text("Keep Awake")
                    .font(.subheadline.weight(.semibold))
                Picker("Keep Awake", selection: Binding(
                    get: { mode },
                    set: { onChangeMode($0) }
                )) {
                    ForEach(KeepAwakeMode.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Keep Mac awake")
            }

            if mode != .off {
                screenRow
            }
            if mode == .on {
                timerRow
            }

            statusLine
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(macName).font(.headline)
                    if isDemo {
                        Text("DEMO")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                if let lastSeen {
                    Text("Last seen \(lastSeen, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isDemo {
                    Text("Sample device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Circle()
                .fill(awakeActive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
        }
    }

    private var screenRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("While awake")
                .font(.subheadline.weight(.semibold))
            Picker("While awake", selection: Binding(
                get: { screen },
                set: { onChangeScreen($0) }
            )) {
                Text("Keep screen on").tag(ScreenMode.screenOn)
                Text("Allow screen off").tag(ScreenMode.screenOff)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Screen behaviour while awake")
        }
    }

    private var timerRow: some View {
        HStack {
            Text("Auto-off after")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Picker("Auto-off after", selection: Binding(
                get: { timerHours },
                set: { onChangeTimer($0) }
            )) {
                ForEach(timerChoices, id: \.self) { h in
                    Text(timerLabel(h)).tag(h)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Auto-off timer")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 8) {
            if waiting {
                ProgressView().controlSize(.small)
                Text("Sent — waiting for your Mac to check in")
            } else {
                Image(systemName: statusSymbol)
                    .foregroundStyle(awakeActive ? .green : .secondary)
                Text(statusText)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch mode {
        case .off:  return "powersleep"
        case .on:   return awakeActive ? "cup.and.saucer.fill" : "hourglass"
        case .auto: return awakeActive ? "sparkles" : "powersleep"
        }
    }

    private var statusText: String {
        switch mode {
        case .off:
            return "Your Mac sleeps normally"
        case .on:
            return awakeActive ? "Awake" : "Starting…"
        case .auto:
            if awakeActive {
                let n = activeAgentCount
                return "Awake · \(n) agent\(n == 1 ? "" : "s") working"
            }
            return "Idle · sleeps when agents finish"
        }
    }
}

// MARK: - Live wrapper

struct MacControlView: View {
    @State private var macStore = MacStatusStore.shared

    // Optimistic local selections; reconciled against the live MacStatus.
    @State private var mode: KeepAwakeMode = .off
    @State private var screen: ScreenMode = .screenOn
    @State private var timerHours: Int = 0

    @State private var waitingCommandId: String?
    @State private var waitTimeout: Task<Void, Never>?

    var body: some View {
        Group {
            if let mac = macStore.primary {
                MacControlCard(
                    macName: mac.name,
                    lastSeen: mac.lastSeen,
                    isDemo: false,
                    mode: mode,
                    screen: screen,
                    timerHours: timerHours,
                    awakeActive: mac.sleepActive,
                    activeAgentCount: mac.activeAgentCount ?? 0,
                    waiting: waitingCommandId != nil,
                    onChangeMode: { newMode in
                        Haptics.selection()
                        mode = newMode
                        send(.setKeepAwakeMode, value: newMode.rawValue)
                    },
                    onChangeScreen: { newScreen in
                        Haptics.selection()
                        screen = newScreen
                        send(.setScreenMode, value: newScreen.rawValue)
                    },
                    onChangeTimer: { hours in
                        Haptics.selection()
                        timerHours = hours
                        send(.setSessionTimerHours, value: String(hours))
                    }
                )
                .onAppear { syncFromMac(mac) }
                .onChange(of: mac) { _, newMac in
                    // Reconcile: clear pending when the Mac acks our command, and
                    // re-sync local selections to the Mac's truth when not waiting.
                    if let cid = waitingCommandId, newMac.lastAppliedCommandId == cid {
                        clearWaiting()
                    }
                    if waitingCommandId == nil { syncFromMac(newMac) }
                }
            }
        }
    }

    private func syncFromMac(_ mac: MacStatusRecord) {
        if let m = mac.keepAwakeMode.flatMap(KeepAwakeMode.init) { mode = m }
        if let s = ScreenMode(rawValue: mac.mode) { screen = s }
        if let h = mac.sessionTimerHours { timerHours = h }
    }

    private func send(_ verb: ControlCommandRecord.Verb, value: String) {
        Task {
            if let cid = await CompanionSyncEngine.shared.sendControlCommand(verb: verb, value: value) {
                waitingCommandId = cid
                startWaitTimeout()
            } else {
                Haptics.warning()
            }
        }
    }

    private func startWaitTimeout() {
        waitTimeout?.cancel()
        waitTimeout = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { clearWaiting() }
        }
    }

    private func clearWaiting() {
        waitTimeout?.cancel()
        waitTimeout = nil
        waitingCommandId = nil
    }
}
