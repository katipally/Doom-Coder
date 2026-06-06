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
    @ObservedObject private var store = IosDeviceProfileCache.shared

    init(connection: Connection, onSelect: (() -> Void)? = nil) {
        self.connection = connection
        self.onSelect = onSelect
    }

    /// v7: the peer iOS DeviceRecord (if known) + the derived connection state.
    private var peer: DeviceRecord? { store.peer(for: connection) }
    private var derived: DerivedDeviceState { store.derivedState(for: connection) }

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
        .accessibilityLabel("\(displayName), \(connection.route.shortLabel), \(derived.displayName)")
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

    /// v7: prefer the iOS-side display name from the peer DeviceRecord; fall
    /// back to a generic "iPhone" if the record hasn't landed yet.
    private var displayName: String {
        peer?.displayName ?? "iPhone"
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
        let name = connection.peerAccountName ?? peer?.accountName
        let email = connection.peerAccountEmail ?? peer?.accountEmail
        // Account identity: prefer real name, then email, else the route label.
        if let name, !name.isEmpty {
            parts.append(name)
            if let email, !email.isEmpty { parts.append(email) }
        } else if let email, !email.isEmpty {
            parts.append(email)
        } else {
            parts.append(connection.route.shortLabel)
        }
        if let model = peer?.model, !model.isEmpty { parts.append(model) }
        if let os = peer?.osVersion, !os.isEmpty { parts.append(os) }
        // Live online dot / last-seen hint.
        if let peer {
            if peer.isOnline() {
                parts.append("Online")
            } else {
                parts.append("last seen \(peer.lastSeen.formatted(.relative(presentation: .named)))")
            }
        }
        if let battery = peer?.battery, battery > 0 {
            parts.append("\(Int(battery * 100))%")
        }
        return parts.joined(separator: " · ")
    }

    /// v7: badge text + color come from the DERIVED state, not Connection.status.
    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(badgeColor)
                .frame(width: 7, height: 7)
            Text(derived.displayName)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(badgeColor.opacity(0.2), in: Capsule())
        .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        switch derived {
        case .active:       return .green
        case .pending:      return .orange
        case .offline:      return .yellow
        case .disconnected: return .red
        }
    }
}
