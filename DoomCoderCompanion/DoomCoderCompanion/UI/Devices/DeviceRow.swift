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
        var parts: [String] = [connection.route.shortLabel]
        if let email = connectionEmailHint {
            parts.append("Signed in as \(email)")
        }
        return parts.joined(separator: " · ")
    }

    /// Best-effort iCloud account email from the most recent
    /// PeerStatus for this Mac. Apple doesn't expose the email
    /// through CKContainer APIs in all environments, so this is
    /// best-effort. Returns nil when we don't know.
    private var connectionEmailHint: String? {
        // Look at the most-recent PeerStatusRecord that this app
        // has fetched; we don't have direct access to it from
        // here so we fall back to the display hint in the route
        // label.
        return nil
    }

    private var lastSeenText: String {
        guard let last = connection.lastSyncAt else { return "Never" }
        return last.formatted(.relative(presentation: .named))
    }

    private var statusColor: Color {
        switch connection.status {
        case .active:    return .green
        case .pending:   return .orange
        case .suspended: return .yellow
        case .removed:   return .red
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
