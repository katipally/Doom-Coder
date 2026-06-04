// DeviceRow.swift — DoomCoder Mac
// Single row in the Connections list. Shows icon, name, route, and status.
// v2.7: the iOS display name ("Yash's iPhone") is looked up from
// IosDeviceProfileCache, which is populated by CloudKitPusher when a
// PeerStatus heartbeat arrives.

import SwiftUI
import DoomCoderCore

struct DeviceRow: View {
    let connection: Connection
    let onSelect: (() -> Void)?

    init(connection: Connection, onSelect: (() -> Void)? = nil) {
        self.connection = connection
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: connection.route.isCrossAppleID ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline)
                Text(connection.route.shortLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
    }

    /// v2.7: prefer the iOS-side display name from the PeerStatus
    /// cache; fall back to a generic "iPhone" if no heartbeat has
    /// landed yet (e.g. just-paired via QR before first heartbeat).
    private var displayName: String {
        IosDeviceProfileCache.shared.name(for: connection.iosDeviceId) ?? "iPhone"
    }

    private var statusBadge: some View {
        Text(connection.status.displayName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeColor.opacity(0.2), in: Capsule())
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        switch connection.status {
        case .active:    return .green
        case .pending:   return .orange
        case .suspended: return .yellow
        case .removed:   return .red
        }
    }
}
