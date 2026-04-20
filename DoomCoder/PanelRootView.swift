import SwiftUI
import AppKit

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
            Text("⌥Space shortcut is taken by another app.")
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Button("Fix") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                WindowOpener.open(.settings)
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
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(masterEnabled ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.06))
                        .frame(width: 32, height: 32)
                    Image(systemName: "bolt.horizontal.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(masterEnabled ? Color.accentColor : .secondary)
                }
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
                Toggle("", isOn: Binding(
                    get: { masterEnabled },
                    set: { on in
                        withAnimation(DCAnim.smooth) { masterEnabled = on }
                        if on { sleepManager.enable() }
                        else if sleepManager.isActive { sleepManager.disable() }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(14)
        }
    }

    private var masterSubtitle: String {
        if !masterEnabled { return "Suspended — nothing is active" }
        if sleepManager.isActive, !tracking.liveSessions.isEmpty {
            let n = tracking.liveSessions.count
            return "Awake · \(n) agent\(n == 1 ? "" : "s") live"
        }
        if sleepManager.isActive { return "Active · Mac awake" }
        if !tracking.liveSessions.isEmpty {
            let n = tracking.liveSessions.count
            return "\(n) agent\(n == 1 ? "" : "s") live"
        }
        return "Ready"
    }

    // MARK: - Keep Mac Awake card (a.k.a. Prevent Sleep)

    private var keepAwakeCard: some View {
        InnerCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    iconChip(system: sleepManager.isActive ? "bolt.fill" : "bolt.slash",
                             active: sleepManager.isActive)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Prevent Sleep")
                            .font(.system(size: 13, weight: .medium))
                        Text(keepAwakeSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .contentTransition(.interpolate)
                    }
                    Spacer()
                    if sleepManager.isActive, !compactElapsed.isEmpty {
                        Text(compactElapsed)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                            .contentTransition(.numericText())
                    }
                }

                // Mode section
                VStack(alignment: .leading, spacing: 6) {
                    Text("MODE")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                    ModeSegmentedControl(mode: Binding(
                        get: { sleepManager.mode },
                        set: { newMode in
                            withAnimation(DCAnim.smooth) { sleepManager.mode = newMode }
                            if masterEnabled, !sleepManager.isActive {
                                sleepManager.enable()
                            }
                        }
                    ), isActive: sleepManager.isActive)
                }

                // Duration section — the ONLY start/stop surface. Tapping a
                // duration starts sleep blocking (or updates the cap); the
                // leading Stop tile disables it.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("DURATION")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(durationSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .contentTransition(.interpolate)
                    }
                    DurationStrip(
                        isActive: sleepManager.isActive,
                        selectedHours: sleepManager.sessionTimerHours,
                        onSelect: { hours in
                            guard masterEnabled else { return }
                            withAnimation(DCAnim.smooth) {
                                sleepManager.sessionTimerHours = hours
                            }
                            // Sleep is already active when DoomCoder is on;
                            // enable only as a belt-and-braces guard.
                            if !sleepManager.isActive { sleepManager.enable() }
                        }
                    )
                }

                if let countdown = sleepManager.screenOffCountdown {
                    statusPill(icon: "display", text: "Display off in \(countdown)s…", tint: .orange)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else if sleepManager.isScreenOff {
                    statusPill(icon: "display", text: "Display off — move mouse to wake", tint: .orange)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .padding(14)
        }
    }

    private var keepAwakeSubtitle: String {
        if sleepManager.isActive {
            switch sleepManager.mode {
            case .screenOn:  return "Screen on · display stays lit"
            case .screenOff: return "Screen off · display sleeps"
            }
        }
        return "Prevent sleep while you work"
    }

    private var compactElapsed: String {
        sleepManager.elapsedTimeString
            .replacingOccurrences(of: "Active for ", with: "")
    }

    private var durationSubtitle: String {
        let h = sleepManager.sessionTimerHours
        if h == 0 { return sleepManager.isActive ? "Runs indefinitely" : "No auto-stop" }
        if let remaining = sleepManager.sessionTimerRemainingText {
            // e.g. "Auto-disable in 1h 23m" → "1h 23m left"
            return remaining
                .replacingOccurrences(of: "Auto-disable in ", with: "")
                + " left"
        }
        return "\(h)h session"
    }

    // MARK: - Agents card

    private var agentsCard: some View {
        InnerCard {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    iconChip(system: "antenna.radiowaves.left.and.right",
                             active: !tracking.liveSessions.isEmpty,
                             activeTint: .green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Agent Tracking")
                            .font(.system(size: 13, weight: .medium))
                        Text(tracking.liveSessions.isEmpty
                             ? "No sessions running"
                             : "Listening for events")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !tracking.liveSessions.isEmpty {
                        Text("\(tracking.liveSessions.count)")
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
            footerItem("gearshape", label: "Settings") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                WindowOpener.open(.settings)
            }
            footerItem("info.circle", label: "About") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                WindowOpener.open(.about)
            }
            footerItem("arrow.triangle.2.circlepath", label: "Updates") {
                updaterViewModel.checkForUpdates()
            }
            .disabled(!updaterViewModel.canCheckForUpdates)
            .opacity(updaterViewModel.canCheckForUpdates ? 1 : 0.4)
            footerItem("power", label: "Quit") {
                sleepManager.disable()
                NSApplication.shared.terminate(nil)
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
        }
    }

    private func statusPill(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption2)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: Capsule())
    }

    enum ActionTone { case accent, destructive, neutral }

    @ViewBuilder
    private func actionBar(icon: String, label: String, tone: ActionTone, action: @escaping () -> Void) -> some View {
        let fg: Color = tone == .destructive ? .red : (tone == .accent ? .white : .primary)
        let bg: Color = tone == .destructive ? Color.red.opacity(0.18)
            : (tone == .accent ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.08))

        PressableButton(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(label).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bg))
        }
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
                Text(label).font(.caption)
                if chevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? -180 : 0))
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
        NSApplication.shared.activate(ignoringOtherApps: true)
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
    }
}

// MARK: - Duration strip (dot indicator)

private struct DurationStrip: View {
    let isActive: Bool
    let selectedHours: Int
    var onSelect: (Int) -> Void

    // 0 = ∞ (default/infinite), then fixed durations.
    private let options: [Int] = [0, 1, 2, 4, 8]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { h in
                let selected: Bool = isActive && selectedHours == h
                Button { onSelect(h) } label: {
                    VStack(spacing: 4) {
                        Text(label(for: h))
                            .font(.caption.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                            .contentTransition(.interpolate)
                        Circle()
                            .fill(selected ? Color.accentColor : Color.white.opacity(0.18))
                            .frame(width: 5, height: 5)
                            .scaleEffect(selected ? 1.2 : 1.0)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .help(helpText(for: h))
                .animation(DCAnim.smooth, value: selected)
            }
        }
        .padding(.horizontal, 2)
    }

    private func label(for h: Int) -> String {
        if h == 0 { return "∞" }
        return "\(h)h"
    }

    private func helpText(for h: Int) -> String {
        if h == 0 { return "Prevent sleep indefinitely" }
        return "Prevent sleep for \(h) hour\(h == 1 ? "" : "s")"
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
            Color(nsColor: NSColor(calibratedWhite: 0.11, alpha: 1.0)) // ~#1C1C1E
            // Subtle top highlight
            LinearGradient(
                colors: [Color.white.opacity(0.06), .clear],
                startPoint: .top, endPoint: .center
            )
            // Subtle grain via blend-mode overlay (keeps cost low; no image assets).
            GrainOverlay()
                .opacity(0.35)
                .blendMode(.overlay)
                .allowsHitTesting(false)
        }
    }
}

private struct GrainOverlay: View {
    var body: some View {
        // Procedural grain: tile a tiny canvas of randomized pixels.
        Canvas { ctx, size in
            var generator = SystemRandomNumberGenerator()
            let step: CGFloat = 2
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    let r = Double(generator.next() & 0xFF) / 255.0
                    let alpha = 0.015 + r * 0.03
                    ctx.fill(
                        Path(CGRect(x: x, y: y, width: step, height: step)),
                        with: .color(Color.white.opacity(alpha))
                    )
                    x += step
                }
                y += step
            }
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
