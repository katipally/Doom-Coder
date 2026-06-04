// MacSwitcher.swift — DoomCoder Companion
// Segmented picker that lets the user focus on one paired Mac. Bound to
// `selectedMacId` in the parent DashboardView. Empty state hides itself.

import SwiftUI
import DoomCoderCore

struct MacSwitcher: View {
    let connections: [Connection]
    @Binding var selectedMacId: String?

    var body: some View {
        if connections.count > 1 {
            Picker("Mac", selection: $selectedMacId) {
                ForEach(connections) { connection in
                    Text(displayName(for: connection)).tag(Optional(connection.macDeviceId))
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
        }
    }

    private func displayName(for connection: Connection) -> String {
        MacStatusStore.shared.byMacId[connection.macDeviceId]?.name ?? "Mac"
    }
}
