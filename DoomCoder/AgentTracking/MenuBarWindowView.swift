import SwiftUI

// Menu-bar window (MenuBarExtra(.window)) content.
//
// Layout per v1.9.0 UX spec:
//   1. Master enable/disable toggle (full-row clickable)
//   2. Mode selector (Screen On / Screen Off) — button pair styled as segmented
//   3. Configure Agents  ›   (opens wizard: agents + channels)
//   4. Track Agents · N on › (opens per-agent tracking toggles)
//   5. Compact footer: Settings · About · Updates · Quit
//
// We deliberately avoid DisclosureGroup / segmented Picker in this scope
// because both have triggered NSHostingView constraint loops inside
// menuBarExtra(.window) on macOS 26. The layout is fully static — safe.
struct MenuBarWindowView: View {
    @Bindable var sleepManager: SleepManager
    var updaterViewModel: CheckForUpdatesViewModel
    @Bindable var tracking: AgentTrackingManager
    @Environment(\.openWindow) private var openWindow

    @State private var trackedOn: Int = 0
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            enableRow
            Divider().padding(.horizontal, 12)
            modeRow
            Divider().padding(.horizontal, 12)
            configureRow
            Divider().padding(.horizontal, 12)
            trackRow
            Divider().padding(.horizontal, 12)
            footer
        }
        .frame(width: 320, height: 320)
        .onAppear { refreshTrackedCount() }
        .onReceive(refreshTimer) { _ in refreshTrackedCount() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(sleepManager.isActive ? Color.accentColor : .secondary)
            Text("DoomCoder").font(.headline)
            Spacer()
            if sleepManager.isActive, !sleepManager.elapsedTimeString.isEmpty {
                Text(sleepManager.elapsedTimeString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var enableRow: some View {
        Button {
            if sleepManager.isActive { sleepManager.disable() } else { sleepManager.enable() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sleepManager.isActive ? "DoomCoder is on" : "Enable DoomCoder")
                        .font(.body)
                    Text(sleepManager.isActive
                         ? "Mac stays awake"
                         : "Keep Mac awake while you work")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { sleepManager.isActive },
                    set: { on in if on { sleepManager.enable() } else { sleepManager.disable() } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .allowsHitTesting(false) // whole row handles the tap
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private var modeRow: some View {
        HStack(spacing: 10) {
            Text("Mode").font(.body)
            Spacer()
            modeButton(.screenOn, label: "Screen On", icon: "sun.max.fill")
            modeButton(.screenOff, label: "Screen Off", icon: "moon.fill")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func modeButton(_ target: DoomCoderMode, label: String, icon: String) -> some View {
        let selected = sleepManager.mode == target
        Button {
            sleepManager.mode = target
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption)
                Text(label).font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3),
                                  lineWidth: 0.5)
            )
            .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    private var configureRow: some View {
        Button {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "configureAgents")
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.2.fill")
                    .font(.body)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Configure Agents").font(.body)
                    Text("Install hooks, set channels")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private var trackRow: some View {
        Button {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "trackAgents")
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.body)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Track Agents").font(.body)
                    Text(trackSubtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if tracking.liveSessions.count > 0 {
                    Text("\(tracking.liveSessions.count)")
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.green.opacity(0.25), in: Capsule())
                        .foregroundStyle(.green)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private var trackSubtitle: String {
        let live = tracking.liveSessions.count
        if live > 0 { return "\(live) live · \(trackedOn) tracked" }
        return "\(trackedOn) of \(TrackedAgent.allCases.count) tracked"
    }

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

    private func refreshTrackedCount() {
        trackedOn = TrackingStore.enabledCount()
    }
}
