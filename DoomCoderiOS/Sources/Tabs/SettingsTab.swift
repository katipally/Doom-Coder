import SwiftUI
import CloudKit

struct SettingsTab: View {
    @ObservedObject var settings = IOSUserSettings.shared
    @State private var iCloudStatus: String = "Checking…"
    @State private var connectedMacs: Int = 0
    @State private var isResettingSubscriptions = false
    @State private var subscriptionResetResult: String? = nil

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
                Section("Keep Mac Awake") {
                    sleepStatusRow
                    Toggle("Enabled", isOn: Binding(
                        get: { settings.sleepEnabled },
                        set: { v in
                            settings.sleepEnabled = v
                            Task { try? await CloudKitClient.shared.writeSleepCommand(type: "toggle", enabled: v) }
                        }
                    ))
                    Picker("Mode", selection: Binding(
                        get: { settings.sleepMode },
                        set: { v in
                            settings.sleepMode = v
                            Task { try? await CloudKitClient.shared.writeSleepCommand(type: "setMode", mode: v) }
                        }
                    )) {
                        Text("Screen On").tag("screenOn")
                        Text("Screen Off").tag("screenOff")
                    }
                    Stepper("Re-arm: \(settings.sleepScreenOffRearmMinutes) min",
                            value: Binding(
                                get: { settings.sleepScreenOffRearmMinutes },
                                set: { v in
                                    settings.sleepScreenOffRearmMinutes = v
                                    Task { try? await CloudKitClient.shared.writeSleepCommand(type: "setRearmMinutes", rearmMinutes: v) }
                                }
                            ), in: 1...60)
                    Stepper("Session timer: \(settings.sleepSessionTimerHours == 0 ? "Off" : "\(settings.sleepSessionTimerHours)h")",
                            value: Binding(
                                get: { settings.sleepSessionTimerHours },
                                set: { v in
                                    settings.sleepSessionTimerHours = v
                                    Task { try? await CloudKitClient.shared.writeSleepCommand(type: "setTimerHours", timerHours: v) }
                                }
                            ), in: 0...24)
                }
                Section("Notifications") {
                    Toggle("Approvals", isOn: $settings.notifyApprovals)
                    Toggle("Failures", isOn: $settings.notifyFailures)
                    Toggle("Session summaries", isOn: $settings.notifySessionSummaries)
                    Toggle("Tool-call updates", isOn: $settings.notifyToolCallUpdates)

                    Button {
                        Task { await resetSubscriptions() }
                    } label: {
                        HStack {
                            if isResettingSubscriptions {
                                ProgressView().tint(.blue)
                                Text("Re-registering…")
                            } else {
                                Image(systemName: "arrow.clockwise.circle")
                                Text("Reset Notification Subscriptions")
                            }
                        }
                    }
                    .disabled(isResettingSubscriptions)

                    if let result = subscriptionResetResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.hasPrefix("✓") ? .green : .red)
                    }
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

    private var sleepStatusRow: some View {
        HStack {
            Image(systemName: settings.sleepEnabled ? "moon.zzz.fill" : "moon")
                .foregroundStyle(settings.sleepEnabled ? .yellow : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.sleepEnabled ? "Active" : "Inactive")
                    .font(.subheadline.weight(.medium))
                if settings.sleepEnabled {
                    let mins = settings.sleepElapsedSec / 60
                    let secs = settings.sleepElapsedSec % 60
                    Text("\(mins)m \(secs)s · Thermal: \(settings.sleepThermalState)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
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

    private func resetSubscriptions() async {
        isResettingSubscriptions = true
        subscriptionResetResult = nil
        await CloudKitSubscriptionHandler.shared.forceReRegister()
        await MainActor.run {
            isResettingSubscriptions = false
            subscriptionResetResult = "✓ Subscriptions re-registered"
        }
        // Auto-clear the success message after 3 seconds
        try? await Task.sleep(for: .seconds(3))
        await MainActor.run { subscriptionResetResult = nil }
    }

    private func clearAll() async {
        await MainActor.run { SessionStore.shared.setHistory([]) }
    }
}

