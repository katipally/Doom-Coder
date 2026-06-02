import SwiftUI
import AppKit
import DoomCoderCore

// Root SwiftUI view for the floating panel.
//
// Layout (top → bottom):
//   DragHandle (hover-only)
//   Master toggle card            ← soft-suspend gate for the whole app
//   Keep Mac Awake card           ← segmented Mode + dot-indicator Duration
//   Agent Tracking card           ← Configure + inline Track accordion
//   Footer (labeled icons)        ← Settings / About / Updates / Quit
//
// Background: solid dark card (#1C1C1E) + subtle inner top stroke.
// Inner cards: flat-lift (#2C2C2E).
// Animation tokens: DCAnim.bouncy for panel+accordion, DCAnim.snap/smooth for micro.
struct PanelRootView: View {
    @Bindable var sleepManager: SleepManager
    var updaterViewModel: CheckForUpdatesViewModel
    @Bindable var tracking: AgentTrackingManager
    var dismiss: () -> Void = {}

    @AppStorage("doomcoder.masterEnabled") private var masterEnabled: Bool = true

    @State private var measuredSize: CGSize = .zero
    @State private var appeared: Bool = false
    @State private var handleHovered: Bool = false
    @State private var agentDetailExpanded: Bool = false

    // Wider panel to fit bento grid (two cards side by side).
    private let panelWidth: CGFloat = 480

    var body: some View {
        // No ScrollView. No frame(height:) constraints fighting each other.
        // Root VStack has fixedSize so it always renders at ideal height.
        // SizeReporter measures that ideal height and drives the NSPanel resize.
        // Two cards sit side-by-side in a bento grid — total height ~380pt,
        // well within any screen.
        VStack(spacing: 0) {
            dragHandle
            if GlobalHotkey.shared.conflictDetected {
                conflictBanner
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            masterCard
                .padding(.horizontal, 14)
                .padding(.top, 2)

            // Bento grid row — Prevent Sleep | Agent Tracking side by side.
            HStack(alignment: .top, spacing: 8) {
                keepAwakeCard
                    .frame(maxWidth: .infinity, alignment: .top)
                agentsCard
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .disabled(!masterEnabled)
            .opacity(masterEnabled ? 1.0 : 0.45)
            .animation(DCAnim.smooth, value: masterEnabled)

            Divider().opacity(0.15).padding(.horizontal, 14)
            footer
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
        .frame(width: panelWidth)
        .fixedSize(horizontal: true, vertical: true)
        .background(PanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .scaleEffect(appeared ? 1.0 : 0.97)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1))
                withAnimation(DCAnim.bouncy) { appeared = true }
            }
            // Opening the panel is the moment the user is most likely watching
            // for a fresh iOS→Mac command or status. Pull immediately instead of
            // waiting up to a full safety-timer interval.
            Task { @MainActor in
                CloudKitPusher.shared.fetchNow()
                CloudKitPusher.shared.publishMacStatus()
            }
        }
        .background(SizeReporter(size: $measuredSize))
        .onChange(of: measuredSize) { _, s in
            guard s.height > 10 else { return }
            let maxH = (NSScreen.main?.visibleFrame.height ?? 800) - 32
            let h = min(s.height, maxH)
            Task { @MainActor in
                FloatingPanelController.shared.resize(
                    to: NSSize(width: panelWidth, height: h)
                )
            }
        }
        .background(WindowOpenerBridge())
    }

    // MARK: - Hotkey conflict banner

    private var conflictBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("⌥Space shortcut is taken by another app.")
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Button("Fix") {
                NSApplication.shared.activate()
                WindowOpener.openSettings()
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
    }

    // MARK: - Drag handle (hover-only)

    private var dragHandle: some View {
        ZStack {
            Color.clear.frame(height: 18)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white.opacity(handleHovered ? 0.28 : 0.0))
                .frame(width: 34, height: 4)
                .animation(DCAnim.smooth, value: handleHovered)
        }
        .contentShape(Rectangle())
        .onHover { handleHovered = $0 }
        .help("Drag to move")
    }

    // MARK: - Master toggle card

    private var masterCard: some View {
        MasterCard {
            HStack(spacing: 12) {
                Image("logo")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .opacity(masterEnabled ? 1.0 : 0.5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("DoomCoder")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(masterSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .contentTransition(.interpolate)
                }
                Spacer()
                HelpTip("Master on/off switch. When turned off, the sleep blocker stops and all agent notifications are suspended. Everything resumes when you turn it back on.")
                Toggle("", isOn: Binding(
                    get: { masterEnabled },
                    set: { on in
                        withAnimation(DCAnim.smooth) { masterEnabled = on }
                        // Record the local-change time so a stale remote master
                        // command (issued before this) can be ignored on apply.
                        UserDefaults.standard.set(Date(), forKey: CloudKitPusherDelegate.masterChangedAtKey)
                        // Master is the app-wide suspend gate. Turning it OFF
                        // releases any keep-awake assertion. Turning it ON does
                        // NOT force keep-awake — the Keep Awake card's
                        // Off/On/Auto selector owns that intent.
                        if !on { sleepManager.disable() }
                        // Publish the new master state so iOS mirrors it promptly.
                        CloudKitPusher.shared.publishMacStatus()
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("DoomCoder")
                .accessibilityValue(masterEnabled ? "On" : "Off")
            }
            .padding(14)
        }
    }

    private var masterSubtitle: String {
        if !masterEnabled { return "Suspended — nothing is active" }
        let n = tracking.hookFreshAgents.count
        if sleepManager.isActive, n > 0 {
            return "Awake · \(n) agent\(n == 1 ? "" : "s") working"
        }
        if sleepManager.isActive { return "Active · Mac awake" }
        if n > 0 { return "\(n) agent\(n == 1 ? "" : "s") working" }
        return "Ready"
    }

    // MARK: - Keep Mac Awake card
    //
    // Off · On · ✦Auto selector (the single keep-awake control), an explicit
    // Screen mode (keep on / allow off), an Auto-off dropdown, and a status
    // line (elapsed, agents working, screen-off, auto-off countdown).

    private var keepAwakeCard: some View {
        InnerCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    iconChip(system: keepAwakeIcon, active: sleepManager.isActive)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Keep Awake")
                            .font(.system(size: 13, weight: .medium))
                        Text(keepAwakeSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .contentTransition(.interpolate)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                // Off / On / Auto — the keep-awake intent.
                KeepAwakeModeControl(mode: Binding(
                    get: { sleepManager.keepAwakeMode },
                    set: { newMode in
                        guard masterEnabled else { return }
                        withAnimation(DCAnim.smooth) { sleepManager.keepAwakeMode = newMode }
                    }
                ))

                // Mode-specific options. Each mode shows only the controls that
                // apply to it (rather than dimming irrelevant ones).
                switch sleepManager.keepAwakeMode {
                case .off:
                    Label("macOS manages sleep normally", systemImage: "powersleep")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)

                case .on:
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("SCREEN", help: "Keep screen on holds the display lit. Allow screen off lets the display sleep after a short delay while the Mac CPU stays awake — saves power and reduces burn-in.")
                        ModeSegmentedControl(mode: $sleepManager.mode, isActive: sleepManager.isActive)
                    }
                    .transition(.opacity)
                    HStack(spacing: 6) {
                        sectionLabel("AUTO-OFF", help: "Automatically turns keep-awake off after the chosen time.")
                        Spacer()
                        autoOffMenu
                    }
                    .transition(.opacity)

                case .auto:
                    EmptyView()
                }

                keepAwakeStatus
            }
            .padding(14)
            .animation(DCAnim.smooth, value: sleepManager.keepAwakeMode)
        }
    }

    @ViewBuilder
    private var keepAwakeStatus: some View {
        if let countdown = sleepManager.screenOffCountdown {
            statusPill(icon: "display", text: "Display off in \(countdown)s…", tint: .orange)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else if sleepManager.isScreenOff {
            statusPill(icon: "display", text: "Display off — move mouse to wake", tint: .orange)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else if sleepManager.keepAwakeMode == .auto {
            let n = sleepManager.activeAgentCount
            if n > 0 {
                // Agents are working: show only the count + expandable per-agent
                // detail. No countdown while work is happening — staleness is
                // handled silently and the only timer the user ever sees is the
                // grace countdown below, once everything has finished.
                VStack(alignment: .leading, spacing: 4) {
                    DisclosureGroup(isExpanded: $agentDetailExpanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(sleepManager.autoStatusLines) { line in
                                agentStatusRow(line)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        statusPill(icon: "sparkles",
                                   text: "\(n) agent\(n == 1 ? "" : "s") working",
                                   tint: .accentColor)
                    }
                    .disclosureGroupStyle(PillDisclosureStyle())
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                statusPill(icon: "moon",
                           text: "Delegated · macOS controls sleep",
                           tint: .secondary)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        } else if let remaining = sleepManager.sessionTimerRemainingText {
            statusPill(icon: "timer", text: remaining, tint: .secondary)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private var autoOffMenu: some View {
        Menu {
            ForEach([0, 1, 2, 4, 8], id: \.self) { h in
                Button {
                    withAnimation(DCAnim.smooth) { sleepManager.sessionTimerHours = h }
                } label: {
                    if sleepManager.sessionTimerHours == h {
                        Label(autoOffLabel(h), systemImage: "checkmark")
                    } else {
                        Text(autoOffLabel(h))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(autoOffLabel(sleepManager.sessionTimerHours))
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Auto-off timer")
        .accessibilityValue(autoOffLabel(sleepManager.sessionTimerHours))
    }

    private func autoOffLabel(_ h: Int) -> String {
        h == 0 ? "Never" : "\(h)h"
    }

    @ViewBuilder
    private func sectionLabel(_ text: String, help: String) -> some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            HelpTip(help)
        }
    }

    private var keepAwakeIcon: String {
        switch sleepManager.keepAwakeMode {
        case .off:  return "powersleep"
        case .on:   return "cup.and.saucer.fill"
        case .auto: return "sparkles"
        }
    }

    private var keepAwakeSubtitle: String {
        switch sleepManager.keepAwakeMode {
        case .off:
            return "Mac sleeps normally"
        case .on:
            return sleepManager.mode == .screenOff ? "On · display sleeps" : "On · display stays lit"
        case .auto:
            let n = sleepManager.activeAgentCount
            if n > 0 { return "Auto · \(n) agent\(n == 1 ? "" : "s") working" }
            return "Auto · macOS controls sleep"
        }
    }

    // MARK: - Agents card

    private var agentsCard: some View {
        InnerCard {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    iconChip(system: "antenna.radiowaves.left.and.right",
                             active: !tracking.hookFreshAgents.isEmpty,
                             activeTint: .green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Agent Tracking")
                            .font(.system(size: 13, weight: .medium))
                        Text(tracking.hookFreshAgents.isEmpty
                             ? "Ready to track"
                             : "Listening for hooks")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !tracking.hookFreshAgents.isEmpty {
                        Text("\(tracking.hookFreshAgents.count)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                            .contentTransition(.numericText())
                    }
                }

                // Flat agent list — always visible
                Divider().opacity(0.4)
                Text("Configured Agents")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
                TrackAccordion(openConfigure: openConfigureWindow)

                compactAction(icon: "gearshape.2.fill", label: "Configure", accent: false) {
                    openConfigureWindow()
                }
            }
            .padding(14)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            footerItem("text.alignleft", label: "Prompts") {
                ToolSurfaceManager.open(.prompts)
            }
            footerItem("note.text", label: "Notes") {
                ToolSurfaceManager.open(.notes)
            }
            footerItem("gearshape", label: "Settings") {
                WindowOpener.openSettings()
            }
            footerItem("arrow.triangle.2.circlepath", label: "Updates") {
                updaterViewModel.checkForUpdates()
            }
            .disabled(!updaterViewModel.canCheckForUpdates)
            .opacity(updaterViewModel.canCheckForUpdates ? 1 : 0.4)
            // Minimize: hide the bar AND all open tool windows, remembering them
            // so they reopen in place next time the bar is shown. Quitting the
            // app lives in the menu-bar right-click menu (⌘Q).
            footerItem("minus.circle", label: "Minimize") {
                ToolSurfaceManager.hideOpenSurfaces()
                dismiss()
            }
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func footerItem(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        PressableButton(tier: .secondary, action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .regular))
                    .accessibilityHidden(true)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 38)
            .contentShape(Rectangle())
        }
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: - Small helpers

    @ViewBuilder
    private func iconChip(system: String, active: Bool, activeTint: Color = .accentColor) -> some View {
        ZStack {
            Circle()
                .fill(active ? activeTint.opacity(0.2) : Color.white.opacity(0.05))
                .frame(width: 30, height: 30)
            Image(systemName: system)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? activeTint : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
        }
    }

    private func agentStatusRow(_ line: SleepManager.AutoAgentLine) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(line.state == "running" ? Color.green
                      : line.state.hasPrefix("idle") ? Color.secondary.opacity(0.4)
                      : Color.orange)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(line.agentDisplayName)
                .font(.caption2.weight(.medium))
            Spacer()
            Text(line.state)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(line.agentType)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
    }

    private func statusPill(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2)
                .accessibilityHidden(true)
            Text(text).font(.caption2)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func compactAction(
        icon: String,
        label: String,
        accent: Bool,
        chevron: Bool = false,
        expanded: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        PressableButton(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2)
                    .accessibilityHidden(true)
                Text(label).font(.caption)
                if chevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? -180 : 0))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent ? Color.accentColor.opacity(0.20) : Color.white.opacity(0.06))
            )
            .foregroundStyle(accent ? Color.accentColor : .secondary)
        }
    }

    private func openConfigureWindow() {
        NSApplication.shared.activate()
        WindowOpener.open(.configureAgents)
    }
}

// MARK: - Mode segmented control (Apple-style)

private struct ModeSegmentedControl: View {
    @Binding var mode: DoomCoderMode
    var isActive: Bool

    var body: some View {
        HStack(spacing: 0) {
            segment(.screenOn, label: "Screen On", icon: "sun.max.fill")
            segment(.screenOff, label: "Screen Off", icon: "moon.fill")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    @ViewBuilder
    private func segment(_ target: DoomCoderMode, label: String, icon: String) -> some View {
        let selected = mode == target
        Button {
            mode = target
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption)
                    .accessibilityHidden(true)
                Text(label).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor.opacity(0.85))
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            )
            .foregroundStyle(selected ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .animation(DCAnim.smooth, value: selected)
        .accessibilityLabel(label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Keep-awake mode control (Off · On · ✦Auto)

private struct KeepAwakeModeControl: View {
    @Binding var mode: KeepAwakeMode

    var body: some View {
        HStack(spacing: 0) {
            segment(.off,  label: "Off",  icon: "powersleep")
            segment(.on,   label: "On",   icon: "cup.and.saucer.fill")
            segment(.auto, label: "Auto", icon: "sparkles")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    @ViewBuilder
    private func segment(_ target: KeepAwakeMode, label: String, icon: String) -> some View {
        let selected = mode == target
        Button {
            mode = target
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                    .accessibilityHidden(true)
                Text(label).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tint(target).opacity(0.85))
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            )
            .foregroundStyle(selected ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .animation(DCAnim.smooth, value: selected)
        .help(helpText(target))
        .accessibilityLabel("\(label) keep awake")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tint(_ m: KeepAwakeMode) -> Color {
        m == .off ? .gray : .accentColor
    }

    private func helpText(_ m: KeepAwakeMode) -> String {
        switch m {
        case .off:  return "Let the Mac sleep normally."
        case .on:   return "Keep the Mac awake until you turn it off or the auto-off timer fires."
        case .auto: return "Keep the Mac awake only while an agent is working; sleep shortly after they finish."
        }
    }
}

// MARK: - Pressable button (hover + press feedback)

struct PressableButton<Label: View>: View {
    enum Tier { case primary, secondary }

    var tier: Tier = .primary
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        let hoverScale: CGFloat = tier == .primary ? 1.015 : 1.0
        let scale = pressed ? 0.97 : (hovered ? hoverScale : 1.0)
        let shadowRadius: CGFloat = (tier == .primary && hovered && !pressed) ? 6 : 0
        let shadowOpacity: Double = (tier == .primary && hovered && !pressed) ? 0.28 : 0

        Button(action: action) { label() }
            .buttonStyle(.plain)
            .overlay(
                // Hover highlight — 6% for secondary (footer), 8% for primary
                // cards. Rendered as a rounded fill on top so it reads even
                // over the existing RoundedRectangle backgrounds.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(hovered ? (tier == .primary ? 0.08 : 0.06) : 0))
                    .allowsHitTesting(false)
            )
            .scaleEffect(scale)
            .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: 2)
            .animation(DCAnim.snap, value: pressed)
            .animation(DCAnim.smooth, value: hovered)
            .onHover { hovered = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in pressed = false }
            )
    }
}

// MARK: - Card containers

private struct MasterCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
            )
    }
}

private struct InnerCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
    }
}

// MARK: - Panel background (dark card + subtle grain)

private struct PanelBackground: View {
    var body: some View {
        ZStack {
            // Liquid Glass — native macOS material with dark vibrancy.
            Rectangle()
                .fill(.ultraThinMaterial)
            // Subtle dark tint to keep contrast on bright desktop backgrounds.
            Color.black.opacity(0.35)
        }
    }
}

// MARK: - Size reporter

private struct SizeReporter: View {
    @Binding var size: CGSize
    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { size = proxy.size }
                .onChange(of: proxy.size) { _, newValue in size = newValue }
        }
    }
}

// MARK: - Pill disclosure style

/// A DisclosureGroupStyle that renders the label at full width (like a pill)
/// with a small chevron on the right, matching the panel's status-pill aesthetic.
private struct PillDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DCAnim.smooth) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 0) {
                    configuration.label
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(configuration.isExpanded ? .degrees(90) : .zero)
                        .animation(DCAnim.smooth, value: configuration.isExpanded)
                        .padding(.trailing, 9)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
