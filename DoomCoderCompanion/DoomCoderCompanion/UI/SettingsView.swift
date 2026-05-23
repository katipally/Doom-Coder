// SettingsView.swift — DoomCoder Companion
// Simplified read-only settings: About, Send Test, Sync Diagnostics

import SwiftUI
import DoomCoderCore

struct SettingsView: View {
    @State private var macStore = MacStatusStore.shared
    @State private var sync = CompanionSyncEngine.shared
    @State private var testSent = false
    
    var body: some View {
        List {
            aboutSection
            testSection
            diagnosticsSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            }
            LabeledContent("Build") {
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
            }
            LabeledContent("Container") {
                Text(CloudKitConstants.containerIdentifier)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                            Text(mac.version)
                                .font(.caption)
                            Text(relativeTime(mac.lastSeen))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
    
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
            Text("Sends a test notification through CloudKit. Requires a paired Mac.")
        }
    }
    
    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            NavigationLink {
                SyncDiagnosticsView()
            } label: {
                Label("Sync diagnostics", systemImage: "wave.3.right")
            }
            
            Button {
                Task { await sync.fetchChanges() }
            } label: {
                Label("Sync now", systemImage: "arrow.clockwise")
            }
        }
    }
    
    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}
