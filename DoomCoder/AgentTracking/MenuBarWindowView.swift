import SwiftUI

// Menu-bar window (MenuBarExtra(.window)) content.
//
// Two-section layout:
//   Section 1 — Keep Awake: sleep toggle, mode selector, session timer
//   Section 2 — Agent Tracking: live sessions, configure/track shortcuts
//   Footer: Settings · About · Updates · Quit
//
// Critical: Do NOT use .animation() modifiers in this view — they cause
// infinite NSHostingView constraint-update loops in menuBarExtra(.window).
// All animations use withAnimation {} in action closures.
struct MenuBarWindowView: View {
    @Bindable var sleepManager: SleepManager
    var updaterViewModel: CheckForUpdatesViewModel
    @Bindable var tracking: AgentTrackingManager
    @Environment(\.openWindow) private var openWindow

    @State private var trackedOn: Int = 0
    @State private var configuredCount: Int = 0
    @State private var detectedCount: Int = 0
    @AppStorage("menubar.trackExpanded") private var trackExpanded: Bool = false
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let timerOptions = [0, 1, 2, 4, 8]

    private var accordionHeight: CGFloat {
        guard trackExpanded else { return 0 }
        if configuredCount == 0 { return 32 }
        return CGFloat(configuredCount) * 36 + 4
    }

    private var liveStripHeight: CGFloat {
        let count = tracking.liveSessions.count
        guard count > 0 else { return 0 }
        return CGFloat(count) * 22 + 12
    }

    private var totalHeight: CGFloat {
        var h: CGFloat = 330
        if sleepManager.sessionTimerRemainingText != nil { h += 22 }
        if sleepManager.screenOffCountdown != nil || sleepManager.isScreenOff { h += 22 }
        h += liveStripHeight
        h += accordionHeight
        return h
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Keep Awake ──────────────────────────────────────
            keepAwakeHeader
            enableRow
            modeRow
            timerRow
            if let remaining = sleepManager.sessionTimerRemainingText {
                timerStatusRow(remaining)
            }
            if let countdown = sleepManager.screenOffCountdown {
                screenOffStatusRow("Display off in \(countdown)s…")
            } else if sleepManager.isScreenOff {
                screenOffStatusRow("Display off — move mouse to wake")
            }

            // ── Section Divider ─────────────────────────────────
            HStack(spacing: 8) {
                VStack { Divider() }
                Circle().fill(.quaternary).frame(width: 3, height: 3)
                VStack { Divider() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            // ── Agent Tracking ──────────────────────────────────
            agentTrackingHeader
            liveActivityStrip
            agentActionsRow
            if trackExpanded {
                TrackAccordion(openConfigure: openConfigureWindow)
                    .frame(height: accordionHeight)
            }

            Spacer(minLength: 0)
            Divider().padding(.horizontal, 12)
            footer
        }
        .frame(width: 320, height: totalHeight)
        .onAppear { refreshTrackedCount() }
        .onReceive(refreshTimer) { _ in refreshTrackedCount() }
    }

    private func openConfigureWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "configureAgents")
    }

    // MARK: - Keep Awake

    private var keepAwakeHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(sleepManager.isActive ? Color.accentColor : .secondary)
            Text("Keep Awake")
                .font(.headline)
            Spacer()
            if sleepManager.isActive, !sleepManager.elapsedTimeString.isEmpty {
                Text(sleepManager.elapsedTimeString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var enableRow: some View {
        Button {
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                sleepManager.toggle()
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sleepManager.isActive ? "Mac stays awake" : "Keep Mac Awake")
                        .font(.body)
                    if sleepManager.isActive {
                        Text(modeStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Prevent sleep while you work")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { sleepManager.isActive },
                    set: { on in
                        withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                            if on { sleepManager.enable() } else { sleepManager.disable() }
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private var modeStatusText: String {
        switch sleepManager.mode {
        case .screenOn:  return "Screen on · display stays lit"
        case .screenOff: return "Screen off · display sleeps"
        }
    }

    private var modeRow: some View {
        HStack(spacing: 8) {
            modeChip(.screenOn, label: "Screen On", icon: "sun.max.fill")
            modeChip(.screenOff, label: "Screen Off", icon: "moon.fill")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func modeChip(_ target: DoomCoderMode, label: String, icon: String) -> some View {
        let selected = sleepManager.mode == target
        Button {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                sleepManager.mode = target
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2)
                Text(label).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 0.5)
            )
            .foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }

    private var timerRow: some View {
        HStack(spacing: 0) {
            Image(systemName: "timer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
            ForEach(timerOptions, id: \.self) { hours in
                let selected = sleepManager.sessionTimerHours == hours
                Button {
                    withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
                        sleepManager.sessionTimerHours = hours
                    }
                } label: {
                    Text(hours == 0 ? "Off" : "\(hours)h")
                        .font(.caption2.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(selected ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func timerStatusRow(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption2)
            Text(text)
                .font(.caption2)
                .contentTransition(.numericText())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }

    private func screenOffStatusRow(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "display")
                .font(.caption2)
            Text(text)
                .font(.caption2)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }

    // MARK: - Agent Tracking

    private var agentTrackingHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.body.weight(.semibold))
                .foregroundStyle(!tracking.liveSessions.isEmpty ? .green : .secondary)
            Text("Agent Tracking")
                .font(.headline)
            Spacer()
            if tracking.liveSessions.count > 0 {
                Text("\(tracking.liveSessions.count) live")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var liveActivityStrip: some View {
        let live = tracking.liveSessions
        if !live.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(live) { session in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(stateColor(session.displayState))
                            .frame(width: 6, height: 6)
                        Image(nsImage: AgentIconProvider.icon(for: session.agent, size: 14))
                            .resizable()
                            .frame(width: 14, height: 14)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        Text(session.agent.displayName)
                            .font(.caption2.weight(.medium))
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                        Text(session.status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(timeAgo(session.updatedAt))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private var agentActionsRow: some View {
        HStack(spacing: 8) {
            Button { openConfigureWindow() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape.2.fill").font(.caption2)
                    Text("Configure").font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.06)))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                    trackExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "eye.fill").font(.caption2)
                    Text("Track").font(.caption)
                    if configuredCount > 0 {
                        Text("\(trackedOn)/\(configuredCount)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: trackExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(trackExpanded ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06))
                )
                .foregroundStyle(trackExpanded ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton("Settings", icon: "gearshape") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
            footerButton("About", icon: "info.circle") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "about")
            }
            footerButton("Updates", icon: "arrow.triangle.2.circlepath") {
                updaterViewModel.checkForUpdates()
            }
            .disabled(!updaterViewModel.canCheckForUpdates)
            footerButton("Quit", icon: "power") {
                sleepManager.disable()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func footerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.body)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: - Helpers

    private func stateColor(_ s: AgentSessionState) -> Color {
        switch s {
        case .running:          return .green
        case .waitingInput:     return .yellow
        case .waitingApproval:  return .orange
        case .completed:        return .gray
        case .failed:           return .red
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "\(secs)s" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h"
    }

    private func refreshTrackedCount() {
        trackedOn = TrackingStore.installedAndEnabledCount()
        configuredCount = TrackAccordion.configuredCount()
        detectedCount = TrackingStore.detectedCount()
    }
}
