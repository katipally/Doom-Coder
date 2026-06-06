// DeviceRow.swift — DoomCoder Companion
// One row in the Devices section. v5 polish: color-tinted route
// glyph (blue for same-Apple-ID, green for cross-account), explicit
// route label, and a subtitle that shows the iCloud account hint
// from the most-recent PeerStatus. Status is a colored pill on
// the right.
//
// Layout follows the v5 plan §6.3: icon (32×32) | name + subtitle
// (flex) | status pill (right-aligned).

import SwiftUI
import DoomCoderCore

struct DeviceRow: View {
    let connection: Connection
    let isSelected: Bool

    private var macName: String {
        let name = MacStatusStore.shared.byMacId[connection.macDeviceId]?.name
        if let name, !name.isEmpty { return name }
        // Fall back to the host name encoded in the share URL or a
        // generic "Mac" if we don't have either.
        return "Mac"
    }

    private var routeIcon: String {
        connection.route.isCrossAppleID
            ? "person.2.crop.square.stack"
            : "macbook"
    }

    private var routeTint: Color {
        connection.route.isCrossAppleID ? .green : .blue
    }

    private var subtitleText: String {
        var parts: [String] = []
        // v6: the Mac owner's iCloud identity (captured from the CKShare on a
        // different-Apple-ID pairing). Same-account shows the route label.
        let name = connection.peerAccountName ?? mac?.accountFullName
        let email = connection.peerAccountEmail ?? mac?.accountEmail
        if let name, !name.isEmpty {
            parts.append(name)
            if let email, !email.isEmpty { parts.append(email) }
        } else if let email, !email.isEmpty {
            parts.append(email)
        } else {
            parts.append(connection.route.shortLabel)
        }
        return parts.joined(separator: " · ")
    }

    private var mac: MacStatusRecord? {
        MacStatusStore.shared.byMacId[connection.macDeviceId]
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

    private var lastSeenText: String {
        guard let last = connection.lastSyncAt else { return "Never" }
        return last.formatted(.relative(presentation: .named))
    }

    private var statusColor: Color {
        switch connection.status {
        case .active:         return .green
        case .pending:        return .orange
        case .suspended:      return .yellow
        case .removed:        return .red
        case .awaitingAccept: return .blue
        case .pendingOnPhone: return .blue
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: routeIcon)
                .font(.title3)
                .foregroundStyle(routeTint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(macName)
                        .font(.headline)
                    originBadge
                    routeBadge
                }
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(connection.status.displayName)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.2), in: Capsule())
                    .foregroundStyle(statusColor)
                Text(lastSeenText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(macName), \(connection.route.shortLabel), \(connection.status.displayName), last seen \(lastSeenText)")
    }
}
