// RemoveConnectionDialog.swift — DoomCoder Companion
// Confirmation dialog when the user wants to remove a paired Mac. Wipes
// the local cache for that Mac and unregisters its share subscription.

import SwiftUI
import DoomCoderCore

struct RemoveConnectionDialog: View {
    let connection: Connection
    let onRemoved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var removing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Remove this Mac?")
                    .font(.title3.weight(.semibold))
                Text("The iPhone will stop showing this Mac's agents and notifications. The Mac's local cache for this iPhone will be cleared the next time it runs.")
                    .foregroundStyle(.secondary)
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                }
                Spacer()
                if let lastSync = connection.lastSyncAt {
                    Text("Last sync \(lastSync.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Remove", role: .destructive) {
                        Task { await remove() }
                    }
                    .disabled(removing)
                }
            }
        }
    }

    private func remove() async {
        removing = true
        await IOSPairingCoordinator.shared.remove(connection: connection)
        removing = false
        onRemoved()
        dismiss()
    }
}
