import SwiftUI
import CloudKit

struct SettingsTab: View {
    @ObservedObject var settings = IOSUserSettings.shared
    @State private var iCloudStatus: String = "Checking…"
    @State private var connectedMacs: Int = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("iCloud") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(iCloudStatus).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Connected Macs")
                        Spacer()
                        Text("\(connectedMacs)").foregroundStyle(.secondary)
                    }
                }
                Section("Notifications") {
                    Toggle("Approvals", isOn: $settings.notifyApprovals)
                    Toggle("Failures", isOn: $settings.notifyFailures)
                    Toggle("Session summaries", isOn: $settings.notifySessionSummaries)
                    Toggle("Tool-call updates", isOn: $settings.notifyToolCallUpdates)
                }
                Section("Privacy") {
                    Toggle("Minimal Mode", isOn: $settings.minimalMode)
                    Text("Strips tool args, prompts, paths from synced payloads.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Live Activity") {
                    Stepper("Max simultaneous: \(settings.liveActivityMaxConcurrent)",
                            value: $settings.liveActivityMaxConcurrent, in: 1...3)
                    Stepper("Auto-dismiss after end: \(settings.liveActivityAutoDismissSec)s",
                            value: $settings.liveActivityAutoDismissSec, in: 5...120, step: 5)
                }
                Section("History") {
                    Stepper("Retention: \(settings.historyRetentionDays) days",
                            value: $settings.historyRetentionDays, in: 1...30)
                    Button("Clear All History", role: .destructive) { Task { await clearAll() } }
                }
                Section("App") {
                    Link("Open Source", destination: URL(string: "https://github.com/katipally/Doom-Coder")!)
                    Link("Help", destination: URL(string: "https://github.com/katipally/Doom-Coder/issues")!)
                    HStack { Text("Version"); Spacer(); Text(appVersion).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Settings")
            .task { await loadStatus() }
            .onChange(of: settings.minimalMode) { SettingsSyncer.shared.scheduleLocalPush() }
            .onChange(of: settings.notifyApprovals) { SettingsSyncer.shared.scheduleLocalPush() }
            .onChange(of: settings.notifyFailures) { SettingsSyncer.shared.scheduleLocalPush() }
            .onChange(of: settings.notifySessionSummaries) { SettingsSyncer.shared.scheduleLocalPush() }
            .onChange(of: settings.notifyToolCallUpdates) { SettingsSyncer.shared.scheduleLocalPush() }
            .onChange(of: settings.liveActivityMaxConcurrent) { SettingsSyncer.shared.scheduleLocalPush() }
            .onChange(of: settings.liveActivityAutoDismissSec) { SettingsSyncer.shared.scheduleLocalPush() }
            .onChange(of: settings.historyRetentionDays) { SettingsSyncer.shared.scheduleLocalPush() }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func loadStatus() async {
        let status = await CloudKitClient.shared.accountStatus()
        switch status {
        case .available: iCloudStatus = "Connected ✓"
        case .noAccount: iCloudStatus = "No iCloud account"
        case .restricted: iCloudStatus = "Restricted"
        case .couldNotDetermine: iCloudStatus = "Unknown"
        case .temporarilyUnavailable: iCloudStatus = "Temporarily unavailable"
        @unknown default: iCloudStatus = "Unknown"
        }
        connectedMacs = await CloudKitClient.shared.fetchMacPresenceCount()
    }

    private func clearAll() async {
        // Mark for re-fetch; CloudKit history is owned by Mac. Local view-only state reset.
        await MainActor.run { SessionStore.shared.setHistory([]) }
    }
}
