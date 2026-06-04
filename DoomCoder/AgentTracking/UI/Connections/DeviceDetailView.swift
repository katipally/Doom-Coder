// DeviceDetailView.swift — DoomCoder Mac
// Detail view for a single paired iOS device. Shows status, route, last
// sync, and a Remove button. Reachable from DeviceRow tap.

import SwiftUI
import DoomCoderCore

struct DeviceDetailView: View {
    let connection: Connection
    @State private var showingRemoveDialog = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "iphone.gen3")
                    .font(.largeTitle)
                VStack(alignment: .leading) {
                    Text("iPhone")
                        .font(.title.weight(.semibold))
                    Text(connection.route.displayName)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            statusGrid
            Spacer()
            HStack {
                Button("Remove…", role: .destructive) {
                    showingRemoveDialog = true
                }
                .controlSize(.large)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 360)
        .sheet(isPresented: $showingRemoveDialog) {
            RemoveDeviceDialog(connection: connection) {
                dismiss()
            }
        }
    }

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
            GridRow {
                Text("Status").foregroundStyle(.secondary)
                Text(connection.status.displayName)
            }
            GridRow {
                Text("Route").foregroundStyle(.secondary)
                Text(connection.route.shortLabel)
            }
            GridRow {
                Text("Last Sync").foregroundStyle(.secondary)
                Text(syncLabel)
            }
            GridRow {
                Text("Paired").foregroundStyle(.secondary)
                Text(connection.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private var syncLabel: String {
        guard let last = connection.lastSyncAt else { return "Never" }
        return last.formatted(.relative(presentation: .named))
    }
}
