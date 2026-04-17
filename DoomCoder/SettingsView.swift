import SwiftUI

// Settings window tabs: General, Agent Bridge, iPhone.
// (The legacy "Tools" tab that managed heuristic CLI/GUI override lists was
// removed in v1.0 along with the heuristic detection stack.)
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

            AgentBridgeSettingsView(agentStatus: agentStatus, socketServer: socketServer)
                .tabItem { Label("Agent Bridge", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(1)

            IPhoneSetupView(relay: iPhoneRelay)
                .tabItem { Label("iPhone", systemImage: "iphone") }
                .tag(2)
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
            Section("General") {
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
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
