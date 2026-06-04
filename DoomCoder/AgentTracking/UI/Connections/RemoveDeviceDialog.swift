// RemoveDeviceDialog.swift — DoomCoder Mac
// Confirmation dialog when the user removes a paired iOS device. The
// dialog explains what will happen on the iOS side so the user isn't
// surprised by data being wiped there.

import SwiftUI
import DoomCoderCore

struct RemoveDeviceDialog: View {
    let connection: Connection
    let onRemoved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var removing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove this iPhone?")
                .font(.title3.weight(.semibold))
            Text("This Mac will stop sending notifications and status updates to the iPhone. The iPhone app will clear its local cache the next time it opens.")
                .foregroundStyle(.secondary)
            if let error {
                Text(error)
                    .foregroundStyle(.red)
            }
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Remove", role: .destructive) {
                    Task { await remove() }
                }
                .disabled(removing)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(minWidth: 380, minHeight: 220)
    }

    private func remove() async {
        removing = true
        await MacPairingCoordinator.shared.remove(connection: connection)
        removing = false
        onRemoved()
        dismiss()
    }
}
