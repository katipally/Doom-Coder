import SwiftUI

// Slim 2-tab shell. The old Agent Bridge + iPhone + Tools tabs are gone —
// all that functionality now lives in the Agent Tracking window, which is
// the primary surface users see. Settings holds only General preferences
// and Advanced developer knobs.
struct SettingsView: View {
    @Bindable var sleepManager: SleepManager
    @Bindable var agentStatus: AgentStatusManager
    var socketServer: SocketServer
    @Bindable var iPhoneRelay: IPhoneRelay
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralTab(sleepManager: sleepManager)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(0)

            AdvancedTab(
                agentStatus: agentStatus,
                socketServer: socketServer,
                iPhoneRelay: iPhoneRelay
            )
            .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            .tag(1)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 8)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @Bindable var sleepManager: SleepManager

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { sleepManager.isLaunchAtLoginEnabled },
                    set: { _ in sleepManager.toggleLaunchAtLogin() }
                ))
            }

            Section("Global Shortcut") {
                LabeledContent("Toggle shortcut") {
                    Text("⌥ Space")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Accessibility") {
                    if sleepManager.hasAccessibilityPermission {
                        Label("Access granted", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant Access") {
                            sleepManager.requestAccessibilityPermission()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                    }
                }

                if !sleepManager.hasAccessibilityPermission {
                    Text("Required for the ⌥ Space global shortcut. After clicking Grant Access, open System Settings → Privacy & Security → Accessibility and enable Doom Coder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                OpenAgentTrackingButton()
            } header: {
                Text("Agent Tracking")
            } footer: {
                Text("The Agent Tracking window is where you install hooks, connect your iPhone, and watch live agent sessions. This is the primary DoomCoder surface.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

// MARK: - Advanced Tab

private struct AdvancedTab: View {
    @Bindable var agentStatus: AgentStatusManager
    var socketServer: SocketServer
    @Bindable var iPhoneRelay: IPhoneRelay
    @State private var bridgeRestartBusy = false
    @State private var reinstallBusy = false
    @State private var reinstallMessage: String?
    @State private var exportMessage: String?

    var body: some View {
        Form {
            Section("Bridge") {
                LabeledContent("Socket") {
                    Text(socketServer.socketPath)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Status") {
                    if socketServer.isRunning {
                        Label("Running", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Offline", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.orange)
                    }
                }
                HStack {
                    Button {
                        restartBridge()
                    } label: {
                        if bridgeRestartBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Restart Bridge")
                        }
                    }
                    .disabled(bridgeRestartBusy)
                }
            }

            Section("Runtimes") {
                LabeledContent("MCP runtime") {
                    Text("v\(MCPRuntime.version)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        redeployRuntimes()
                    } label: {
                        if reinstallBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Redeploy Runtimes")
                        }
                    }
                    .disabled(reinstallBusy)
                    if let reinstallMessage {
                        Text(reinstallMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Delivery Log") {
                LabeledContent("Entries") {
                    Text("\(iPhoneRelay.deliveryLog.count)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Export…") { exportDeliveryLog() }
                    Button("Clear") { iPhoneRelay.clearDeliveryLog() }
                    if let exportMessage {
                        Text(exportMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                OpenAgentTrackingButton()
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func restartBridge() {
        bridgeRestartBusy = true
        Task {
            socketServer.stop()
            try? await Task.sleep(for: .milliseconds(250))
            socketServer.start()
            bridgeRestartBusy = false
        }
    }

    private func redeployRuntimes() {
        reinstallBusy = true
        reinstallMessage = nil
        Task {
            do {
                try MCPRuntime.deploy()
                reinstallMessage = "Done."
            } catch {
                reinstallMessage = error.localizedDescription
            }
            reinstallBusy = false
        }
    }

    private func exportDeliveryLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "doomcoder-delivery-log.json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let payload = iPhoneRelay.deliveryLog.map { d -> [String: String] in
                [
                    "timestamp": ISO8601DateFormatter().string(from: d.timestamp),
                    "channel": d.channel,
                    "status": d.success ? "success" : "failure",
                    "detail": d.detail
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
                try? data.write(to: url)
                exportMessage = "Saved \(payload.count) entries."
            }
        }
    }
}

private struct OpenAgentTrackingButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "configure")
        } label: {
            Label("Open Configure Agents…", systemImage: "rectangle.stack.badge.play")
        }
    }
}
