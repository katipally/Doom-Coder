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
                    originBadge
                    routeBadge
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

    @ViewBuilder private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    /// v7: every connection is manual (picker+accept, or code/QR/link). Legacy
    /// `.auto` rows from earlier builds fold into "Manual" too.
    @ViewBuilder private var originBadge: some View {
        switch connection.pairingOrigin {
        case .reinstall: badge("Reconnected", .orange)
        default:         badge("Manual", .purple)
        }
    }

    @ViewBuilder private var routeBadge: some View {
        if connection.route.isCrossAppleID { badge("Different iCloud", .green) }
        else { badge("Same iCloud", .teal) }
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
        var parts: [String] = []
        let profile = IosDeviceProfileCache.shared.byId[connection.iosDeviceId]
        let name = connection.peerAccountName ?? profile?.accountName
        let email = connection.peerAccountEmail ?? profile?.accountEmail
        // Account identity: prefer real name, then email, else the route label.
        if let name, !name.isEmpty {
            parts.append(name)
            if let email, !email.isEmpty { parts.append(email) }
        } else if let email, !email.isEmpty {
            parts.append(email)
        } else {
            parts.append(connection.route.shortLabel)
        }
        if let model = profile?.model, !model.isEmpty {
            parts.append(model)
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
        case .active:         return .green
        case .pending:        return .orange
        case .suspended:      return .yellow
        case .removed:        return .red
        case .awaitingAccept: return .blue
        case .pendingOnPhone: return .blue
        }
    }
}
