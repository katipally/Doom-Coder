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
//
// Audit 2026-06: this view is 894 lines and holds optimistic-ack state
// (`waitingCommandId`, `desiredMaster`, `waitingMasterCommandId`, the
// timeout Tasks, the ack-poll loop) as `@State` properties. A proper
// view-model extraction was deferred to Phase 3 because the view body
// is too tangled to refactor in a single PR without dedicated review.
// The properties below are documented as the migration surface for that
// future PR.

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

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // No container-level .animation() here. A container animation leaks
        // upward through the parent VStack and animates conditional rows
        // (screenRow / timerRow) appearing or disappearing — causing the
        // entire section to overshoot. Animation is scoped tightly inside
        // each segment label instead (pill + foreground color only).
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
                            .fill(tint(opt))
                            .matchedGeometryEffect(id: "selectionPill", in: pill)
                    }
                }
                // Pill slides only within the segmented control itself.
                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: selected)
            )
            .foregroundStyle(selected ? Color.white : Color.secondary)
            // Foreground color crossfade scoped to the label, not the card.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(opt))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Selection tints. The macOS panel uses the system accent (blue) for the
/// active segment and conveys state by fill + label weight, not hue — so we
/// match that here instead of the old orange/yellow/indigo gradients, which
/// didn't read as Apple-native. "Off" stays neutral grey to signal inactive.
private func keepAwakeTint(_ m: KeepAwakeMode) -> Color {
    switch m {
    case .off:  return Color(.systemGray)
    case .on:   return .accentColor
    case .auto: return .accentColor
    }
}

private func screenTint(_ s: ScreenMode) -> Color {
    switch s {
    case .screenOn:  return .accentColor
    case .screenOff: return .accentColor
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

                // Conditional rows must not inherit any ambient animation from
                // IconSegmented — use transaction to strip it so they snap in/out
                // without the overshooting spring from the pill animation.
                if mode == .on {
                    screenRow
                        .transaction { $0.animation = nil }
                    timerRow
                        .transaction { $0.animation = nil }
                }
            }

            statusLine
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Audit 2026-06: adopt the iOS 26 Liquid Glass material so the
        // card matches the Prompts/Notes "Glass" surfaces. We use
        // `.glassEffect(.regular)` with the card's outer shape. Older
        // OS fall back to the previous `secondarySystemGroupedBackground`
        // automatically (the modifier is iOS 26+).
        .background {
            if #available(iOS 26.0, *) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                Color(.secondarySystemGroupedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
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
    // Audit 2026-06: gate the segmented pill + opacity animations on
    // Reduce Motion so users who opted out don't see the snappy
    // 0.15-0.22s transitions.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Optimistic local selections; reconciled against the live MacStatus.
    @State private var masterEnabled: Bool = true
    @State private var mode: KeepAwakeMode = .off
    @State private var screen: ScreenMode = .screenOn
    @State private var timerHours: Int = 0

    // Sleep/screen/timer commands reconcile by command-id ack.
    @State private var waitingCommandId: String?
    @State private var waitTimeout: Task<Void, Never>?
    // Set when the wait timeout fires without Mac ack — cleared on retry or success.
    @State private var showTimeoutError = false

    // Master reconciles by VALUE (separate tracker) — the desired master state is
    // confirmed when the Mac publishes masterEnabled == desiredMaster, or acks the
    // exact command id, or the safety timeout fires.
    @State private var desiredMaster: Bool?
    @State private var waitingMasterCommandId: String?
    @State private var masterTimeout: Task<Void, Never>?
    /// Active fetch loop that runs only while a command/master ack is pending,
    /// so the Mac's reply is pulled in within seconds instead of waiting for an
    /// opportunistic silent push or the 30 s foreground poll.
    @State private var ackPoll: Task<Void, Never>?

    /// Matches the .offline threshold in MacReachabilityBanner (15 minutes).
    private let offlineThreshold: TimeInterval = 900

    private var isWaiting: Bool { waitingCommandId != nil || desiredMaster != nil }

    @State private var agentDetailExpanded: Bool = false

    // Renders directly as List sections (DoomCoder master + Keep Awake), mirroring
    // the macOS floating panel layout. The Mac device-info header lives in
    // Settings ▸ Connection — the dashboard stays focused on controls + status.
    var body: some View {
        Group {
            if let mac = macStore.primary {
                masterSection(mac)
                keepAwakeSection(mac)
            }
        }
        .onAppear {
            // Don't clobber an optimistic selection that's still awaiting a Mac
            // ack — the section can re-appear (list virtualization) mid-flight.
            if let mac = macStore.primary, waitingCommandId == nil, desiredMaster == nil {
                syncFromMac(mac)
            }
        }
        .onChange(of: macStore.primary) { _, newMac in
            if let newMac { reconcile(newMac) }
        }
        .onDisappear {
            ackPoll?.cancel()
            ackPoll = nil
        }
    }

    // MARK: - Master section (DoomCoder on/off)

    @ViewBuilder
    private func masterSection(_ mac: MacStatusRecord) -> some View {
        Section {
            // Reachability warning rides above the master row so it never leaves
            // an empty section when the Mac is fresh.
            MacReachabilityBanner()
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            HStack(spacing: 12) {
                Image("logo-square")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .opacity(masterEnabled ? 1.0 : 0.5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DoomCoder").font(.body.weight(.semibold))
                    Text(masterSubtitle(mac))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.interpolate)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { masterEnabled },
                    set: { on in
                        Haptics.selection()
                        masterEnabled = on
                        desiredMaster = on
                        // Start the safety timeout up-front so a hung/long CloudKit
                        // submit can never leave the UI stuck in "waiting".
                        startMasterTimeout()
                        sendMaster(on)
                    }
                ))
                .labelsHidden()
                .accessibilityLabel("DoomCoder on your Mac")
                .accessibilityValue(masterEnabled ? "On" : "Off")
            }
            .padding(.vertical, 2)
        }
    }

    private func masterSubtitle(_ mac: MacStatusRecord) -> String {
        if !masterEnabled { return "Suspended — nothing is active" }
        // Snoozed wins regardless of activity.
        if mac.isSnoozed == true { return "Snoozed · Mac stays awake" }
        let n = mac.activeAgentCount ?? 0
        if mac.sleepActive, n > 0 { return "Awake · \(n) agent\(n == 1 ? "" : "s") working" }
        if mac.sleepActive {
            return mac.autoSignal == "user_active"
                ? "Awake · you're active"
                : "Active · Mac awake"
        }
        return "Ready"
    }

    // MARK: - Keep Awake section (Off / On / Auto)

    @ViewBuilder
    private func keepAwakeSection(_ mac: MacStatusRecord) -> some View {
        let offline = Date().timeIntervalSince(mac.lastSeen) >= offlineThreshold
        Section {
            // Snooze banner: shown above the segmented control when the Mac
            // has a snooze override active. Tapping the cancel button issues
            // a command. Live countdown driven by the server's snoozeUntil.
            if let s = currentSnoozeDuration(mac) {
                snoozeBanner(duration: s, until: mac.snoozeUntil)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
            }

            IconSegmented(
                options: KeepAwakeMode.allCases,
                selection: mode,
                title: { $0.displayName },
                symbol: { $0.symbol },
                tint: keepAwakeTint,
                accessibilityLabel: { "\($0.displayName) keep awake" },
                onSelect: { newMode in
                    Haptics.selection()
                    mode = newMode
                    send(.setKeepAwakeMode, value: newMode.rawValue)
                }
            )
            .listRowSeparator(.hidden)

            if mode == .on {
                VStack(alignment: .leading, spacing: 8) {
                    Text("While awake").font(.subheadline.weight(.semibold))
                    IconSegmented(
                        options: ScreenMode.allCases,
                        selection: screen,
                        title: { $0.displayName },
                        symbol: { $0.symbol },
                        tint: screenTint,
                        accessibilityLabel: { $0.displayName },
                        onSelect: { newScreen in
                            Haptics.selection()
                            screen = newScreen
                            send(.setScreenMode, value: newScreen.rawValue)
                        }
                    )
                }
                .listRowSeparator(.hidden)
            }

            if mode == .on {
                Picker("Auto-off after", selection: Binding(
                    get: { timerHours },
                    set: { hours in
                        Haptics.selection()
                        timerHours = hours
                        send(.setSessionTimerHours, value: String(hours))
                    }
                )) {
                    ForEach(timerChoices, id: \.self) { h in
                        Text(timerLabel(h)).tag(h)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Auto-off timer")
            }

            statusRow(mac, offline: offline)
        } header: {
            Text("Keep Awake")
        }
        .disabled(!masterEnabled)
        .opacity(masterEnabled ? 1.0 : 0.5)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: mode)
    }

    // MARK: - Snooze banner (Auto mode override indicator)

    private func currentSnoozeDuration(_ mac: MacStatusRecord) -> SnoozeDuration? {
        guard mac.isSnoozed == true else { return nil }
        if let raw = mac.snoozeDuration, let s = SnoozeDuration(rawValue: raw) { return s }
        return .indefinite
    }

    @ViewBuilder
    private func snoozeBanner(duration: SnoozeDuration, until: Date?) -> some View {
        let isIndefinite = duration == .indefinite
        let active = isIndefinite || (until.map { $0 > Date() } ?? true)
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Snoozed")
                    .font(.caption.weight(.semibold))
                if isIndefinite {
                    Text("Until you turn it off")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let until {
                    HStack(spacing: 4) {
                        Text("Releases in")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(timerInterval: Date.now...until, countsDown: true)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if active {
                Button("Cancel") {
                    Haptics.tap()
                    send(.setSnooze, value: "")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Cancel snooze")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func statusRow(_ mac: MacStatusRecord, offline: Bool) -> some View {
        if isWaiting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sent — waiting for your Mac to check in")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        } else if showTimeoutError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Mac didn't respond")
                Spacer()
                Button("Retry") {
                    showTimeoutError = false
                    Haptics.tap()
                    send(.setKeepAwakeMode, value: mode.rawValue)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Retry sending command to Mac")
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        } else if offline {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange).accessibilityHidden(true)
                Text("Mac unreachable — changes apply when it reconnects")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        } else if mode == .auto, mac.sleepActive, let n = mac.activeAgentCount, n > 0 {
            // Auto mode with active agents: expandable detail.
            // Prefers the new dominant-signal pill (handles the "you're active"
            // case) over the old count-based display when both signals fire.
            if mac.autoSignal == "user_active" {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap.fill").foregroundStyle(.green).accessibilityHidden(true)
                    Text("You're active · Mac stays awake")
                    Spacer()
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                DisclosureGroup(isExpanded: $agentDetailExpanded) {
                    if let lines = decodeAgentLines(mac.agentStatusJSON) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(lines) { line in
                                agentDetailRow(line)
                            }
                        }
                        .padding(.top, 4)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(.green).accessibilityHidden(true)
                        Text("\(n) agent\(n == 1 ? "" : "s") working")
                        Spacer()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        } else if mode == .auto, mac.sleepActive, mac.autoSignal == "user_active" {
            // Auto with no agents but the user is at the keyboard.
            HStack(spacing: 6) {
                Image(systemName: "hand.tap.fill").foregroundStyle(.green).accessibilityHidden(true)
                Text("You're active · Mac stays awake")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        } else if mode == .auto, mac.sleepActive, mac.autoSignal == "snoozed" {
            // Auto is holding due to a snooze. The banner above already
            // shows the countdown — keep the row simple here.
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz.fill").foregroundStyle(.orange).accessibilityHidden(true)
                Text("Snooze holding sleep")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        } else if mode == .auto, !mac.sleepActive, let graceEnd = mac.autoGraceEndsAt, graceEnd > Date() {
            // Grace period countdown
            HStack(spacing: 6) {
                Image(systemName: "timer").accessibilityHidden(true)
                Text("Grace · releasing in ")
                Text(timerInterval: Date.now...graceEnd, countsDown: true)
                    .monospacedDigit()
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol(mac))
                    .foregroundStyle(mac.sleepActive ? .green : .secondary)
                    .accessibilityHidden(true)
                Text(statusText(mac))
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private func statusSymbol(_ mac: MacStatusRecord) -> String {
        // Snoozed always shows the zzz moon regardless of mode.
        if mac.isSnoozed == true { return "moon.zzz.fill" }
        switch mode {
        case .off:  return "powersleep"
        case .on:   return mac.sleepActive ? "cup.and.saucer.fill" : "hourglass"
        case .auto: return mac.sleepActive ? "sparkles" : "powersleep"
        }
    }

    private func statusText(_ mac: MacStatusRecord) -> String {
        // Snoozed text wins regardless of mode.
        if mac.isSnoozed == true { return "Snoozed — Mac stays awake" }
        switch mode {
        case .off:  return "Your Mac sleeps normally"
        case .on:   return mac.sleepActive ? "Awake" : "Starting…"
        case .auto:
            if mac.sleepActive {
                if mac.autoSignal == "user_active" { return "You're active · Mac stays awake" }
                if let n = mac.activeAgentCount, n > 0 { return "\(n) agent\(n == 1 ? "" : "s") working" }
                return "Awake"
            }
            return "Delegated · macOS controls sleep"
        }
    }

    // MARK: - Agent detail helpers (Auto mode expandable)

    private struct AgentLine: Decodable, Identifiable {
        var id: String { key.isEmpty ? raw : key }  // unique session key from Mac
        let name: String
        let raw: String
        let key: String     // session key = "agent::sessionId" — unique per session
        let state: String
        let type: String
        let idleSecs: Int
        let pidAlive: Bool

        // Backward compat: key defaults to raw if not present (older Mac clients)
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name     = try c.decode(String.self, forKey: .name)
            raw      = try c.decode(String.self, forKey: .raw)
            key      = (try? c.decode(String.self, forKey: .key)) ?? raw
            state    = try c.decode(String.self, forKey: .state)
            type     = try c.decode(String.self, forKey: .type)
            idleSecs = try c.decode(Int.self,    forKey: .idleSecs)
            pidAlive = try c.decode(Bool.self,   forKey: .pidAlive)
        }
        enum CodingKeys: String, CodingKey {
            case name, raw, key, state, type, idleSecs, pidAlive
        }
    }

    private func decodeAgentLines(_ json: String?) -> [AgentLine]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([AgentLine].self, from: data)
    }

    private func agentDetailRow(_ line: AgentLine) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(line.state == "running" ? Color.green
                      : line.state.hasPrefix("idle") ? Color.secondary.opacity(0.4)
                      : Color.orange)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(line.name).font(.caption.weight(.medium))
            Spacer()
            Text(line.state).font(.caption).foregroundStyle(.secondary)
            Text(line.type)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(.secondary)
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
        showTimeoutError = false
        Task {
            if let cid = await CompanionSyncEngine.shared.sendControlCommand(verb: verb, value: value) {
                waitingCommandId = cid
                startWaitTimeout()
            } else {
                Haptics.warning()
                showTimeoutError = true
            }
        }
    }

    /// Convenience for value-less verbs (cancelSnooze, etc.). Empty value
    /// is the convention for "no payload".
    private func send(_ verb: ControlCommandRecord.Verb) {
        send(verb, value: "")
    }

    private func sendMaster(_ on: Bool) {
        showTimeoutError = false
        Task {
            if let cid = await CompanionSyncEngine.shared.sendControlCommand(
                verb: .setMasterEnabled, value: on ? "true" : "false") {
                waitingMasterCommandId = cid
                // Timeout was already started in onChangeMaster.
            } else {
                Haptics.warning()
                clearMasterWaiting()
                showTimeoutError = true
            }
        }
    }

    private func startWaitTimeout() {
        startAckPoll()
        waitTimeout?.cancel()
        waitTimeout = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            showTimeoutError = true
            clearWaiting(fromTimeout: true)
        }
    }

    private func clearWaiting(fromTimeout: Bool = false) {
        waitTimeout?.cancel()
        waitTimeout = nil
        waitingCommandId = nil
        if !fromTimeout { showTimeoutError = false }
        stopAckPollIfIdle()
    }

    private func startMasterTimeout() {
        startAckPoll()
        masterTimeout?.cancel()
        masterTimeout = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            showTimeoutError = true
            clearMasterWaiting(fromTimeout: true)
        }
    }

    private func clearMasterWaiting(fromTimeout: Bool = false) {
        masterTimeout?.cancel()
        masterTimeout = nil
        desiredMaster = nil
        waitingMasterCommandId = nil
        if !fromTimeout { showTimeoutError = false }
        stopAckPollIfIdle()
    }

    /// Polls CloudKit every 2.5 s while any command ack is pending. `fetchChanges`
    /// is single-flight (guarded by `fetchInProgress`), so overlapping ticks are
    /// safe. Each fetch runs `reconcile`, which clears the waiting state as soon
    /// as the Mac's ack/value-match lands. Self-terminates when nothing pends.
    private func startAckPoll() {
        guard ackPoll == nil else { return }
        ackPoll = Task {
            while !Task.isCancelled,
                  waitingCommandId != nil || waitingMasterCommandId != nil {
                await CompanionSyncEngine.shared.fetchChanges()
                try? await Task.sleep(for: .milliseconds(2500))
            }
        }
    }

    private func stopAckPollIfIdle() {
        if waitingCommandId == nil && waitingMasterCommandId == nil {
            ackPoll?.cancel()
            ackPoll = nil
        }
    }
}
