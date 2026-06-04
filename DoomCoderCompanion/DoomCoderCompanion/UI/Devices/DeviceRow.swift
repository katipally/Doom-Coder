// DeviceRow.swift — DoomCoder Companion
// One row in the Devices section: shows Mac name (looked up via the
// MacStatusStore snapshot when available), connection status, and route.

import SwiftUI
import DoomCoderCore

struct DeviceRow: View {
    let connection: Connection
    let isSelected: Bool

    private var macName: String {
        MacStatusStore.shared.byMacId[connection.macDeviceId]?.name ?? "Mac"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: connection.route.isCrossAppleID ? "person.2.crop.square.stack" : "macbook")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(macName)
                    .font(.headline)
                Text(connection.route.shortLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .font(.body.weight(.semibold))
            } else {
                Text(connection.status.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
