// MacControlView.swift — DoomCoder Companion
// The "Your Mac" remote-control card. Lets the user drive the Mac's master
// suspend gate (on/off) and keep-awake state (Off / On / Auto), screen
// behaviour, and auto-off timer from iOS.
//
// Writer path: each change issues a ControlCommandRecord (see CompanionSyncEngine
// .sendControlCommand). The Mac applies it on its next fetch and acks via
// MacStatusRecord.lastAppliedCommandId / masterEnabled — we reconcile optimistic
// UI against that. CloudKit cannot wake a sleeping Mac, so copy never implies the
// change is instant; we show "waiting for your Mac to check in" until it lands.

import SwiftUI
import DoomCoderCore

/// Auto-off timer choices (hours; 0 = never).
private let timerChoices: [Int] = [0, 1, 2, 4, 8]
private func timerLabel(_ h: Int) -> String { h == 0 ? "Never" : "\(h)h" }

// MARK: - Icon-rich segmented control (matches the Mac panel aesthetic)

/// A compact, icon + label segmented control with a per-option tint. Mirrors the
/// Mac `KeepAwakeModeControl` so the iOS card reads as the same product rather
/// than a blank stock segmented picker.
private struct IconSegmented<Option: Hashable>: View {
    let options: [Option]
    let selection: Option
    let title: (Option) -> String
    let symbol: (Option) -> String
    let tint: (Option) -> Color
    let accessibilityLabel: (Option) -> String
    let onSelect: (Option) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { opt in
                segment(opt)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
    }

    @ViewBuilder
    private func segment(_ opt: Option) -> some View {
        let selected = opt == selection
        Button {
            onSelect(opt)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol(opt)).font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
                Text(title(opt)).font(.subheadline.weight(.medium))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tint(opt).gradient)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            )
            .foregroundStyle(selected ? .white : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: selected)
        .accessibilityLabel(accessibilityLabel(opt))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Per-mode accent tints (the "color tints" requested for the sleep card).
private func keepAwakeTint(_ m: KeepAwakeMode) -> Color {
    switch m {
    case .off:  return .gray
    case .on:   return .orange
    case .auto: return .accentColor
    }
}

private func screenTint(_ s: ScreenMode) -> Color {
    switch s {
    case .screenOn:  return .yellow
    case .screenOff: return .indigo
    }
}

// MARK: - Presentational card (shared by live + demo)

struct MacControlCard: View {
    let macName: String
    let lastSeen: Date?
    let isDemo: Bool
    let isOffline: Bool       // true when Mac heartbeat is >10 min stale

    let masterEnabled: Bool
    let mode: KeepAwakeMode
    let screen: ScreenMode
    let timerHours: Int

    let awakeActive: Bool
    let activeAgentCount: Int
    let waiting: Bool

    var onChangeMaster: (Bool) -> Void
    var onChangeMode: (KeepAwakeMode) -> Void
    var onChangeScreen: (ScreenMode) -> Void
    var onChangeTimer: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            masterRow

            if masterEnabled {
                keepAwakeSection

                if mode != .off {
                    screenRow
                }
                if mode == .on {
                    timerRow
                }
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
                .fill(isOffline ? Color.red : (awakeActive ? Color.green : Color.secondary.opacity(0.4)))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
        }
    }

    private var masterRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DoomCoder")
                    .font(.subheadline.weight(.semibold))
                Text(masterEnabled ? "Active on your Mac" : "Suspended — nothing is running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { masterEnabled },
                set: { onChangeMaster($0) }
            ))
            .labelsHidden()
            .accessibilityLabel("DoomCoder on your Mac")
            .accessibilityValue(masterEnabled ? "On" : "Off")
        }
    }

    private var keepAwakeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep Awake")
                .font(.subheadline.weight(.semibold))
            IconSegmented(
                options: KeepAwakeMode.allCases,
                selection: mode,
                title: { $0.displayName },
                symbol: { $0.symbol },
                tint: keepAwakeTint,
                accessibilityLabel: { "\($0.displayName) keep awake" },
                onSelect: onChangeMode
            )
        }
    }

    private var screenRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("While awake")
                .font(.subheadline.weight(.semibold))
            IconSegmented(
                options: ScreenMode.allCases,
                selection: screen,
                title: { $0.displayName },
                symbol: { $0.symbol },
                tint: screenTint,
                accessibilityLabel: { $0.displayName },
                onSelect: onChangeScreen
            )
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
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel("Auto-off timer")
            .accessibilityValue(timerLabel(timerHours))
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 8) {
            if waiting {
                ProgressView().controlSize(.small)
                Text("Sent — waiting for your Mac to check in")
            } else if isOffline {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Mac unreachable — changes apply when it reconnects")
            } else if !masterEnabled {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Suspended — turn DoomCoder on to control your Mac")
            } else {
                Image(systemName: statusSymbol)
                    .foregroundStyle(awakeActive ? .green : .secondary)
                    .accessibilityHidden(true)
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
    @State private var masterEnabled: Bool = true
    @State private var mode: KeepAwakeMode = .off
    @State private var screen: ScreenMode = .screenOn
    @State private var timerHours: Int = 0

    // Sleep/screen/timer commands reconcile by command-id ack.
    @State private var waitingCommandId: String?
    @State private var waitTimeout: Task<Void, Never>?

    // Master reconciles by VALUE (separate tracker) — the desired master state is
    // confirmed when the Mac publishes masterEnabled == desiredMaster, or acks the
    // exact command id, or the safety timeout fires.
    @State private var desiredMaster: Bool?
    @State private var waitingMasterCommandId: String?
    @State private var masterTimeout: Task<Void, Never>?

    /// Matches the .offline threshold in MacReachabilityBanner (10 minutes).
    private let offlineThreshold: TimeInterval = 600

    private var isWaiting: Bool { waitingCommandId != nil || desiredMaster != nil }

    var body: some View {
        Group {
            if let mac = macStore.primary {
                let offline = Date().timeIntervalSince(mac.lastSeen) >= offlineThreshold
                MacControlCard(
                    macName: mac.name,
                    lastSeen: mac.lastSeen,
                    isDemo: false,
                    isOffline: offline,
                    masterEnabled: masterEnabled,
                    mode: mode,
                    screen: screen,
                    timerHours: timerHours,
                    awakeActive: mac.sleepActive,
                    activeAgentCount: mac.activeAgentCount ?? 0,
                    waiting: isWaiting,
                    onChangeMaster: { on in
                        Haptics.selection()
                        masterEnabled = on
                        desiredMaster = on
                        // Start the safety timeout up-front so a hung/long CloudKit
                        // submit can never leave the UI stuck in "waiting".
                        startMasterTimeout()
                        sendMaster(on)
                    },
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
                    reconcile(newMac)
                }
            }
        }
    }

    private func reconcile(_ mac: MacStatusRecord) {
        // Sleep/screen/timer ack by command-id.
        if let cid = waitingCommandId, mac.lastAppliedCommandId == cid {
            clearWaiting()
        }
        // Value-based fallback: when several commands land in one Mac fetch they
        // share the single `lastAppliedCommandId` field (only the last survives),
        // so also clear once the Mac's published state matches our optimistic
        // selection. Achieving the desired state IS the success condition.
        if waitingCommandId != nil {
            let modeMatches = (mac.keepAwakeMode.flatMap(KeepAwakeMode.init) ?? mode) == mode
            let screenMatches = (ScreenMode(rawValue: mac.mode) ?? screen) == screen
            let timerMatches = (mac.sessionTimerHours ?? timerHours) == timerHours
            if modeMatches && screenMatches && timerMatches { clearWaiting() }
        }
        // Master reconcile by value (or exact ack).
        if let want = desiredMaster {
            let macMaster = mac.masterEnabled ?? true
            if macMaster == want || (waitingMasterCommandId != nil && mac.lastAppliedCommandId == waitingMasterCommandId) {
                clearMasterWaiting()
            }
        }
        // Re-sync local selections to the Mac's truth only when nothing pending.
        if waitingCommandId == nil && desiredMaster == nil {
            syncFromMac(mac)
        }
    }

    private func syncFromMac(_ mac: MacStatusRecord) {
        masterEnabled = mac.masterEnabled ?? true
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

    private func sendMaster(_ on: Bool) {
        Task {
            if let cid = await CompanionSyncEngine.shared.sendControlCommand(
                verb: .setMasterEnabled, value: on ? "true" : "false") {
                waitingMasterCommandId = cid
                // Timeout was already started in onChangeMaster.
            } else {
                Haptics.warning()
                clearMasterWaiting()
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

    private func startMasterTimeout() {
        masterTimeout?.cancel()
        masterTimeout = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { clearMasterWaiting() }
        }
    }

    private func clearMasterWaiting() {
        masterTimeout?.cancel()
        masterTimeout = nil
        desiredMaster = nil
        waitingMasterCommandId = nil
    }
}
