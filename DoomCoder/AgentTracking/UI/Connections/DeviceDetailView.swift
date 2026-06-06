// DeviceDetailView.swift — DoomCoder Mac
// Detail view for a single paired iOS device. v5 polish: same
// Route / Pairing origin / Share ID rows as the iOS side, plus
// an inline banner explaining the situation when the iPhone
// hasn't sent a heart-beat in 5+ minutes (suspended) or 7+
// days (stale).

import SwiftUI
import DoomCoderCore

struct DeviceDetailView: View {
    let connection: Connection
    @State private var showingRemoveDialog = false
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = IosDeviceProfileCache.shared

    private var peer: DeviceRecord? { store.peer(for: connection) }
    private var derived: DerivedDeviceState { store.derivedState(for: connection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: routeIcon)
                    .font(.system(size: 36))
                    .foregroundStyle(routeTint)
                VStack(alignment: .leading) {
                    Text(peer?.displayName ?? "Device")
                        .font(.title.weight(.semibold))
                    Text(connection.route.displayName)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if derived == .offline {
                suspendedBanner
            }

            statusGrid
            Spacer()
            HStack {
                Button("Remove…", role: .destructive) {
                    showingRemoveDialog = true
                }
                .controlSize(.large)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 420)
        .sheet(isPresented: $showingRemoveDialog) {
            RemoveDeviceDialog(connection: connection) {
                dismiss()
            }
        }
    }

    private var routeIcon: String {
        connection.route.isCrossAppleID
            ? "iphone.gen3.radiowaves.left.and.right"
            : "iphone.gen3"
    }

    private var routeTint: Color {
        connection.route.isCrossAppleID ? .green : .blue
    }

    private var suspendedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(.orange)
            Text("This iPhone hasn't checked in for a while. It may be offline, in airplane mode, or its DoomCoder app may have been uninstalled.")
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
            GridRow {
                Text("Status").foregroundStyle(.secondary)
                Text(derived.displayName)
            }
            GridRow {
                Text("Route").foregroundStyle(.secondary)
                Text(connection.route.shortLabel)
            }
            if let model = peer?.model, !model.isEmpty {
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    Text(model)
                }
            }
            if let os = peer?.osVersion, !os.isEmpty {
                GridRow {
                    Text("OS").foregroundStyle(.secondary)
                    Text(os)
                }
            }
            GridRow {
                Text("Pairing").foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Image(systemName: connection.pairingOrigin.systemImage)
                    Text(connection.pairingOrigin.displayName)
                }
            }
            if let ref = connection.ckShareRef {
                GridRow {
                    Text("Share ID").foregroundStyle(.secondary)
                    Text(ref.shareURLString)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            GridRow {
                Text("Last Sync").foregroundStyle(.secondary)
                Text(syncLabel)
            }
            GridRow {
                Text("Paired").foregroundStyle(.secondary)
                Text(connection.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private var syncLabel: String {
        // v7: prefer the peer DeviceRecord's lastSeen (authoritative heartbeat).
        let last = peer?.lastSeen ?? connection.lastSyncAt
        guard let last, last > .distantPast else { return "Never" }
        return last.formatted(.relative(presentation: .named))
    }
}
