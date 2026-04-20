import SwiftUI

// Menu-bar window (MenuBarExtra(.window)) content.
//
// Two-section layout:
//   Section 1 — Sleep blocker: toggle, mode selector, session timer
//   Section 2 — Agent Tracking: live sessions, configure/track shortcuts
//   Footer: icon-only (Settings · About · Updates · Quit)
//
// Critical: Do NOT use .animation() modifiers in this view — they cause
// infinite NSHostingView constraint-update loops in menuBarExtra(.window).
// All animations use withAnimation {} in action closures.
// .symbolEffect() and .contentTransition() are safe to use.
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

    /// Compact elapsed time for inline display: "<1m", "5m", "1h 2m"
    private var compactElapsed: String {
        let full = sleepManager.elapsedTimeString
        guard !full.isEmpty else { return "" }
        return full.replacingOccurrences(of: "Active for ", with: "")
    }

    private var accordionHeight: CGFloat {
        guard trackExpanded else { return 0 }
        if configuredCount == 0 { return 40 }
        return CGFloat(configuredCount) * 36 + 8
    }

    private var liveStripHeight: CGFloat {
        let count = tracking.liveSessions.count
        guard count > 0 else { return 0 }
        return CGFloat(count) * 22 + 12
    }

    private var totalHeight: CGFloat {
        var h: CGFloat = 260
        if sleepManager.sessionTimerRemainingText != nil { h += 22 }
        if sleepManager.screenOffCountdown != nil || sleepManager.isScreenOff { h += 22 }
        h += liveStripHeight
        h += accordionHeight
        return h
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Sleep Blocker ────────────────────────────────────
            enableRow
            modeRow
            timerRow
            if let remaining = sleepManager.sessionTimerRemainingText {
                timerStatusRow(remaining)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let countdown = sleepManager.screenOffCountdown {
                screenOffStatusRow("Display off in \(countdown)s…")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if sleepManager.isScreenOff {
                screenOffStatusRow("Display off — move mouse to wake")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // ── Section Divider ─────────────────────────────────
            HStack(spacing: 8) {
                VStack { Divider() }
                Circle().fill(.quaternary).frame(width: 3, height: 3)
                VStack { Divider() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)

            // ── Agent Tracking ──────────────────────────────────
            agentTrackingHeader
            liveActivityStrip
            agentActionsRow
            if trackExpanded {
                TrackAccordion(openConfigure: openConfigureWindow)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.04))
                            .padding(.horizontal, 8)
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().padding(.horizontal, 12).padding(.top, 4)
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

    // MARK: - Sleep Blocker

    private var enableRow: some View {
        Button {
            withAnimation(DCAnim.bouncy) {
                sleepManager.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: sleepManager.isActive ? "bolt.fill" : "bolt.slash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(sleepManager.isActive ? Color.accentColor : .secondary)
                            .symbolEffect(.bounce, value: sleepManager.isActive)
                        Text(sleepManager.isActive ? "Mac stays awake" : "Keep Mac Awake")
                            .font(.body)
                    }
                    Text(sleepManager.isActive ? modeStatusText : "Prevent sleep while you work")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.interpolate)
                }
                Spacer()
                if sleepManager.isActive, !compactElapsed.isEmpty {
                    Text(compactElapsed)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText())
                }
                Toggle("", isOn: Binding(
                    get: { sleepManager.isActive },
                    set: { on in
                        withAnimation(DCAnim.bouncy) {
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
            .padding(.top, 12)
            .padding(.bottom, 6)
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
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func modeChip(_ target: DoomCoderMode, label: String, icon: String) -> some View {
        let selected = sleepManager.mode == target
        Button {
            withAnimation(DCAnim.smooth) {
                sleepManager.mode = target
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                    .contentTransition(.symbolEffect(.replace))
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
                    withAnimation(DCAnim.snap) {
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
                .contentTransition(.interpolate)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }

    // MARK: - Agent Tracking

    private var agentTrackingHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(!tracking.liveSessions.isEmpty ? .green : .secondary)
                .symbolEffect(.variableColor.iterative, isActive: !tracking.liveSessions.isEmpty)
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
        .padding(.vertical, 5)
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
                            .symbolEffect(.pulse, isActive: session.displayState == .running)
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
                            .contentTransition(.interpolate)
                        Spacer()
                        Text(timeAgo(session.updatedAt))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .contentTransition(.numericText())
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .bottom))
                    ))
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
                withAnimation(DCAnim.bouncy) {
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
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .rotationEffect(.degrees(trackExpanded ? -180 : 0))
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
        .padding(.vertical, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            footerIcon("gearshape", label: "Settings") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
            footerIcon("info.circle", label: "About") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "about")
            }
            footerIcon("arrow.triangle.2.circlepath", label: "Check for Updates") {
                updaterViewModel.checkForUpdates()
            }
            .disabled(!updaterViewModel.canCheckForUpdates)
            .opacity(updaterViewModel.canCheckForUpdates ? 1 : 0.4)
            footerIcon("power", label: "Quit") {
                sleepManager.disable()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func footerIcon(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
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
