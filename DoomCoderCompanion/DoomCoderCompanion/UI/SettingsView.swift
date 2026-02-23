// SettingsView.swift — DoomCoder Companion
// Read-only settings: connection, notifications, about, test push, diagnostics.
// Sync is consolidated to a single "Force Sync Now" here (pull-to-refresh on the
// Agents list does the lightweight incremental refresh). Notifications can be
// enabled here as a fallback to the connect flow — they are always optional.

import SwiftUI
import CloudKit
import UserNotifications
import DoomCoderCore

struct SettingsView: View {
    @State private var macStore = MacStatusStore.shared
    @State private var sync = CompanionSyncEngine.shared
    @State private var testSent = false
    @State private var isForceSyncing = false
    @State private var forceSyncDone = false
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var showConnect = false

    var body: some View {
        List {
            connectionSection
            notificationsSection
            aboutSection
            testSection
            diagnosticsSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showConnect) {
            ConnectFlowView(onFinished: {})
        }
        .task { await refreshNotifStatus() }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section("Connection") {
            if let mac = macStore.primary {
                LabeledContent("Connected to") {
                    Text(mac.name).foregroundStyle(.secondary)
                }
                Button {
                    Haptics.tap()
                    showConnect = true
                } label: {
                    Label("Switch Mac", systemImage: "arrow.triangle.2.circlepath")
                }
            } else {
                Button {
                    Haptics.tap()
                    showConnect = true
                } label: {
                    Label("Connect your Mac", systemImage: "link")
                }
            }
        }
    }

    // MARK: - Notifications

    @ViewBuilder
    private var notificationsSection: some View {
        Section {
            switch notifStatus {
            case .authorized, .provisional, .ephemeral:
                LabeledContent("Notifications") {
                    Label("Enabled", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            case .notDetermined:
                Button {
                    Task { await requestNotifications() }
                } label: {
                    Label("Enable Notifications", systemImage: "bell.badge")
                }
            default:
                Button {
                    openSystemSettings()
                } label: {
                    Label("Turn on in Settings", systemImage: "bell.slash")
                }
            }
        } footer: {
            Text("Optional. Used only to alert you when an agent on your Mac needs attention.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            }
            LabeledContent("Build") {
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
            }
            LabeledContent("Last sync") {
                if let ts = sync.lastSyncAt {
                    Text(ts, style: .relative).foregroundStyle(.secondary)
                } else {
                    Text("Never").foregroundStyle(.secondary)
                }
            }

            if !macStore.byMacId.isEmpty {
                ForEach(Array(macStore.byMacId.values), id: \.macId) { mac in
                    LabeledContent(mac.name) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(mac.version).font(.caption)
                            Text(relativeTime(mac.lastSeen))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Test push

    private var testSection: some View {
        Section {
            Button {
                Task {
                    await sync.sendTestNotification()
                    testSent = true
                    try? await Task.sleep(for: .seconds(3))
                    testSent = false
                }
            } label: {
                Label(testSent ? "Sent ✓" : "Send Test Push", systemImage: "bell.badge")
            }
            .disabled(macStore.primary == nil || testSent)
        } footer: {
            Text("Sends a test notification through CloudKit. Requires a connected Mac.")
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Button {
                guard !isForceSyncing else { return }
                isForceSyncing = true
                forceSyncDone = false
                Task {
                    await sync.forceFetchAll()
                    isForceSyncing = false
                    forceSyncDone = true
                    Haptics.success()
                    try? await Task.sleep(for: .seconds(2))
                    forceSyncDone = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isForceSyncing {
                        ProgressView().controlSize(.small)
                    } else if forceSyncDone {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isForceSyncing ? "Syncing…" : forceSyncDone ? "Up to date" : "Force Sync Now")
                }
            }
            .disabled(isForceSyncing)

            NavigationLink {
                SyncDiagnosticsView()
            } label: {
                Label("Sync diagnostics", systemImage: "wave.3.right")
            }
        }
    }

    // MARK: - Helpers

    private func refreshNotifStatus() async {
        notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        await refreshNotifStatus()
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h ago"
        } else {
            return "\(Int(interval / 86400))d ago"
        }
    }
}
