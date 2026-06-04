// ConnectionDiagnosticsView.swift — DoomCoder Mac
// Developer-oriented screen that prints the current Connection table,
// lastSync, share metadata, and any pending errors. Reachable from
// DeviceDetailView. Used to debug pairing across Apple IDs.

import SwiftUI
import DoomCoderCore

struct ConnectionDiagnosticsView: View {
    @ObservedObject private var store = PairingStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection Diagnostics")
                .font(.title3.weight(.semibold))
            if store.connections.isEmpty {
                ContentUnavailableView(
                    "No connections",
                    systemImage: "stethoscope",
                    description: Text("Add a device first.")
                )
            } else {
                ScrollView {
                    ForEach(store.connections) { connection in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connection \(connection.id.prefix(8))")
                                .font(.headline)
                            Text("mac: \(connection.macDeviceId)")
                                .font(.system(.caption, design: .monospaced))
                            Text("ios: \(connection.iosDeviceId)")
                                .font(.system(.caption, design: .monospaced))
                            Text("route: \(connection.route.displayName)")
                                .font(.caption)
                            Text("status: \(connection.status.displayName)")
                                .font(.caption)
                            if let share = connection.ckShareRef {
                                Text("share: \(share.shareURLString)")
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(2)
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .padding()
    }
}
