// DeviceDetailView.swift — DoomCoder Companion
// Detail view for a paired Mac. v5 polish: explicit Route / iCloud
// account / Pairing origin rows, plus a Disconnect button whose
// footer copy is different for same-account vs cross-account pairs
// (auto-pairs don't mention "share" since there's no share to revoke).

import SwiftUI
import DoomCoderCore

struct DeviceDetailView: View {
    let connection: Connection
    @Environment(\.dismiss) private var dismiss
    @State private var showingConfirm = false
    @State private var removing = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: routeIcon)
                        .font(.system(size: 36))
                        .foregroundStyle(routeTint)
                        .frame(width: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.headline)
                        Text(routeSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Connection") {
                LabeledContent("Status") { statusBadge }
                if let last = connection.lastSyncAt {
                    LabeledContent("Last sync", value: last.formatted(.relative(presentation: .named)))
                } else {
                    LabeledContent("Last sync", value: "Never")
                }
                LabeledContent("Paired", value: connection.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section("Route") {
                LabeledContent("Type") {
                    HStack(spacing: 4) {
                        Image(systemName: connection.route.isCrossAppleID
                              ? "person.2.crop.square.stack"
                              : "icloud")
                            .foregroundStyle(routeTint)
                        Text(connection.route.displayName)
                    }
                }
                if let ref = connection.ckShareRef {
                    LabeledContent("Share ID") {
                        Text(ref.shareURLString)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                LabeledContent("Pairing origin") {
                    HStack(spacing: 4) {
                        Image(systemName: connection.pairingOrigin.systemImage)
                            .foregroundStyle(.secondary)
                        Text(connection.pairingOrigin.displayName)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showingConfirm = true
                } label: {
                    HStack {
                        if removing {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                        }
                        Text(removing ? "Disconnecting…" : "Disconnect")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(removing)
            } footer: {
                Text(removeFooter)
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog(
            "Disconnect from \(displayName)?",
            isPresented: $showingConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task { await doRemove() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(disconnectMessage)
        }
    }

    private func doRemove() async {
        removing = true
        await IOSPairingCoordinator.shared.remove(connection: connection)
        removing = false
        dismiss()
    }

    private var displayName: String {
        let name = MacStatusStore.shared.byMacId[connection.macDeviceId]?.name
        return (name?.isEmpty == false ? name : nil) ?? "Mac"
    }

    private var routeIcon: String {
        connection.route.isCrossAppleID
            ? "person.2.crop.square.stack"
            : "macbook"
    }

    private var routeTint: Color {
        connection.route.isCrossAppleID ? .green : .blue
    }

    private var routeSubtitle: String {
        connection.route.isCrossAppleID
            ? "iCloud Share (different Apple ID)"
            : "iCloud (same Apple ID)"
    }

    private var removeFooter: String {
        if connection.isAutoPaired {
            return "Disconnecting stops the iPhone from mirroring this Mac's agents and notifications. The Mac won't be asked to revoke anything — auto-pairs use the same-Apple-ID private zone."
        }
        return "Disconnecting removes this Mac from your device list. The Mac will be notified to stop syncing this device and you can revoke the share from iCloud settings if you want to fully unlink."
    }

    private var disconnectMessage: String {
        if connection.isAutoPaired {
            return "Your iPhone will stop showing this Mac's agents and notifications. The Mac doesn't need to do anything — the connection is via the same Apple ID."
        }
        return "The Mac's agents and notifications will stop appearing on this iPhone."
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch connection.status {
        case .active:
            Label("Active", systemImage: "circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)
        case .suspended:
            Label("Offline", systemImage: "circle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline)
        case .pending:
            Label("Connecting", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
                .font(.subheadline)
        case .removed:
            Label("Removed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.subheadline)
        @unknown default:
            Text(connection.status.displayName)
        }
    }
}
