// DeviceRow.swift — DoomCoder Mac
// Single row in the Connections list. v5 polish: color-tinted
// route glyph (blue for same-Apple-ID, green for cross-account),
// explicit "Auto (same Apple ID)" / "Reconnected" badge, and a
// subtitle that shows the iOS device's full name + the iCloud
// account hint when we have it.

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
            Image(systemName: routeIcon)
                .font(.title2)
                .foregroundStyle(routeTint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.headline)
                    if connection.pairingOrigin == .auto {
                        Text("Auto")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    } else if connection.pairingOrigin == .reinstall {
                        Text("Reconnected")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName), \(connection.route.shortLabel), \(connection.status.displayName)")
    }

    /// v2.7: prefer the iOS-side display name from the PeerStatus
    /// cache; fall back to a generic "iPhone" if no heartbeat has
    /// landed yet (e.g. just-paired via QR before first heartbeat).
    private var displayName: String {
        IosDeviceProfileCache.shared.name(for: connection.iosDeviceId) ?? "iPhone"
    }

    private var routeIcon: String {
        connection.route.isCrossAppleID
            ? "iphone.gen3.radiowaves.left.and.right"
            : "iphone.gen3"
    }

    private var routeTint: Color {
        connection.route.isCrossAppleID ? .green : .blue
    }

    private var subtitleText: String {
        var parts: [String] = [connection.route.shortLabel]
        if let profile = IosDeviceProfileCache.shared.byId[connection.iosDeviceId],
           !profile.model.isEmpty {
            parts.append(profile.model)
        }
        return parts.joined(separator: " · ")
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
