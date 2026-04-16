import SwiftUI

// Settings window tabs: General, Tools, Agent Bridge, iPhone.
struct SettingsView: View {
    @Bindable var sleepManager: SleepManager
    var appDetector: AppDetector
    @Bindable var agentStatus: AgentStatusManager
    var socketServer: SocketServer
    @Bindable var iPhoneRelay: IPhoneRelay
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralTab(sleepManager: sleepManager)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(0)

            ToolsTab(appDetector: appDetector)
                .tabItem { Label("Tools", systemImage: "terminal") }
                .tag(1)

            AgentBridgeSettingsView(agentStatus: agentStatus, socketServer: socketServer)
                .tabItem { Label("Agent Bridge", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(2)

            IPhoneSetupView(relay: iPhoneRelay)
                .tabItem { Label("iPhone", systemImage: "iphone") }
                .tag(3)
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

// MARK: - Tools Tab

private struct ToolsTab: View {
    var appDetector: AppDetector

    @State private var customCLIBinaries: [String] = []
    @State private var customGUIBundles: [String] = []
    @State private var newCLIEntry = ""
    @State private var newGUIEntry = ""
    @State private var showingCLIField = false
    @State private var showingGUIField = false

    var body: some View {
        Form {
            Section {
                Text("Add custom CLI binary names or app bundle IDs that weren't auto-detected. These are merged with the dynamic scan results.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom CLI Tools") {
                ForEach(customCLIBinaries, id: \.self) { bin in
                    HStack {
                        Text(bin)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button {
                            customCLIBinaries.removeAll { $0 == bin }
                            saveCLI()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if showingCLIField {
                    HStack {
                        TextField("Binary name (e.g. myagent)", text: $newCLIEntry)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button("Add") {
                            let bin = newCLIEntry.trimmingCharacters(in: .whitespaces)
                            if !bin.isEmpty, !customCLIBinaries.contains(bin) {
                                customCLIBinaries.append(bin)
                                saveCLI()
                                appDetector.refresh()
                            }
                            newCLIEntry = ""
                            showingCLIField = false
                        }
                        .disabled(newCLIEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") {
                            newCLIEntry = ""
                            showingCLIField = false
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        showingCLIField = true
                    } label: {
                        Label("Add CLI Tool", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                }
            }

            Section("Custom App Bundle IDs") {
                ForEach(customGUIBundles, id: \.self) { bundle in
                    HStack {
                        Text(bundle)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            customGUIBundles.removeAll { $0 == bundle }
                            saveGUI()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if showingGUIField {
                    HStack {
                        TextField("Bundle ID (e.g. com.myide.app)", text: $newGUIEntry)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button("Add") {
                            let bid = newGUIEntry.trimmingCharacters(in: .whitespaces)
                            if !bid.isEmpty, !customGUIBundles.contains(bid) {
                                customGUIBundles.append(bid)
                                saveGUI()
                                appDetector.refresh()
                            }
                            newGUIEntry = ""
                            showingGUIField = false
                        }
                        .disabled(newGUIEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") {
                            newGUIEntry = ""
                            showingGUIField = false
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        showingGUIField = true
                    } label: {
                        Label("Add App Bundle ID", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .onAppear { loadValues() }
    }

    private func loadValues() {
        customCLIBinaries = UserDefaults.standard.stringArray(forKey: "doomcoder.customCLIBinaries") ?? []
        customGUIBundles  = UserDefaults.standard.stringArray(forKey: "doomcoder.customGUIBundles")  ?? []
    }

    private func saveCLI() {
        UserDefaults.standard.set(customCLIBinaries, forKey: "doomcoder.customCLIBinaries")
    }

    private func saveGUI() {
        UserDefaults.standard.set(customGUIBundles, forKey: "doomcoder.customGUIBundles")
    }
}
