// DeviceDetailView.swift — DoomCoder Companion
// Detail view for a paired Mac, reachable from the Devices section. Shows
// route, status, last sync, and exposes Remove.

import SwiftUI
import DoomCoderCore

struct DeviceDetailView: View {
    let connection: Connection
    @State private var showingRemoveDialog = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Status", value: connection.status.displayName)
                LabeledContent("Route", value: connection.route.displayName)
                if let last = connection.lastSyncAt {
                    LabeledContent("Last sync", value: last.formatted(.relative(presentation: .named)))
                } else {
                    LabeledContent("Last sync", value: "Never")
                }
                LabeledContent("Paired", value: connection.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section {
                Button("Remove…", role: .destructive) {
                    showingRemoveDialog = true
                }
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingRemoveDialog) {
            RemoveConnectionDialog(connection: connection) {
                dismiss()
            }
        }
    }

    private var displayName: String {
        MacStatusStore.shared.byMacId[connection.macDeviceId]?.name ?? "Mac"
    }
}
