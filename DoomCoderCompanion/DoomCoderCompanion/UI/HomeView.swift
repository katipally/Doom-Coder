// HomeView.swift — DoomCoder Companion
// Primary dashboard: shows the primary Mac's live status, a PreventSleep
// control card, an agent-activity grid, and a Wake-on-LAN button.

import SwiftUI
import Network
import DoomCoderCore

struct HomeView: View {

    @State private var macStatus  = MacStatusStore.shared
    @State private var sessionStore = SessionStore.shared
    @State private var wolStore   = WoLStore.shared
    @State private var settings   = SettingsStore.shared
    @State private var wifiAvailable = false
    @State private var wakePending   = false
    @State private var wakeError: String?

    // Path monitor runs for the lifetime of this view.
    private let pathMonitor = NWPathMonitor()

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
        .onAppear {
            startPathMonitor()
            Task { await CompanionSyncEngine.shared.ensureSubscriptions() }
        }
        .onDisappear { pathMonitor.cancel() }
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
                WakeCard(
                    profile: wolStore.primary,
                    wifiAvailable: wifiAvailable,
                    isPending: wakePending,
                    errorMessage: wakeError,
                    onWake: sendWoL
                )
            }
            .padding()
        }
    }

    // MARK: - Wi-Fi path monitor

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                self.wifiAvailable = path.usesInterfaceType(.wifi)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "home.pathmonitor"))
    }

    // MARK: - Wake-on-LAN action

    private func sendWoL() {
        guard let profile = wolStore.primary else {
            wakeError = "No WoL profile for this Mac."
            return
        }
        wakePending = true
        wakeError = nil

        // Log the attempt as a ControlCommand for timeline visibility.
        if let macId = macStatus.primary?.macId {
            _ = CommandPublisher.shared.send(verb: .wakeMac, targetMacId: macId)
        }

        Task {
            do {
                try await WakeOnLAN.wake(macAddresses: profile.macAddresses)
            } catch {
                wakeError = error.localizedDescription
            }
            wakePending = false
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
            .foregroundStyle(asleep ? .secondary : .green)
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
            VStack(alignment: .leading, spacing: 12) {
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

                Stepper("Session timer: \(localHours) hr\(localHours == 1 ? "" : "s")", value: $localHours, in: 0...8, step: 1)
                    .onChange(of: localHours) { _, new in
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
        } label: {
            Label("Prevent Sleep", systemImage: "moon.zzz.fill")
        }
        .onAppear {
            localMode  = settings.current.mode == "screenOn" ? 0 : 1
            localHours = settings.current.sessionTimerHrs
        }
    }

    private func sendToggleMaster() -> AsyncThrowingStream<CommandPublisher.Status, Error>? {
        guard let macId = MacStatusStore.shared.primary?.macId else { return nil }
        return CommandPublisher.shared.send(verb: .toggleMaster, targetMacId: macId)
    }
}

// MARK: - AgentsCard

private struct AgentsCard: View {
    var sessionStore: SessionStore

    var body: some View {
        GroupBox {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 8) {
                ForEach(TrackedAgent.allCases, id: \.rawValue) { agent in
                    AgentTile(agent: agent, sessionStore: sessionStore)
                }
            }
        } label: {
            Label("Agents", systemImage: "cpu")
        }
    }
}

private struct AgentTile: View {
    let agent: TrackedAgent
    var sessionStore: SessionStore

    private var activeSession: SessionRecord? {
        sessionStore.live.first { $0.agent == agent.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(agent.displayName)
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(activeSession != nil ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
            }
            if let s = activeSession {
                Text(s.displayState)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Idle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - WakeCard

private struct WakeCard: View {
    let profile: WoLProfileRecord?
    let wifiAvailable: Bool
    let isPending: Bool
    let errorMessage: String?
    let onWake: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let err = errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button(action: onWake) {
                    Label(isPending ? "Sending…" : "Wake Mac", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!wifiAvailable || profile == nil || isPending)

                if !wifiAvailable {
                    Text("Connect to Wi-Fi to use Wake-on-LAN")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if profile == nil {
                    Text("No WoL profile synced from Mac yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("Wake on LAN", systemImage: "network")
        }
    }
}
