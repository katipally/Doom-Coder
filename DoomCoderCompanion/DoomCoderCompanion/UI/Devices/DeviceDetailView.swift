// DeviceDetailView.swift — DoomCoder Companion
// Detail view for a paired Mac. Tapping a row in DevicesSection navigates here.
// Shows live connection status and a prominent Disconnect button.

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
                    Image(systemName: deviceIcon)
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                        .frame(width: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.headline)
                        Text(connection.route.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Connection") {
                LabeledContent("Status") {
                    statusBadge
                }
                if let last = connection.lastSyncAt {
                    LabeledContent("Last sync", value: last.formatted(.relative(presentation: .named)))
                } else {
                    LabeledContent("Last sync", value: "Never")
                }
                LabeledContent("Paired", value: connection.createdAt.formatted(date: .abbreviated, time: .shortened))
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
                Text("Disconnecting removes this Mac from your device list. The Mac will be notified to stop syncing this device.")
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
            Text("The Mac's agents and notifications will stop appearing on this iPhone.")
        }
    }

    private func doRemove() async {
        removing = true
        await IOSPairingCoordinator.shared.remove(connection: connection)
        removing = false
        dismiss()
    }

    private var displayName: String {
        MacStatusStore.shared.byMacId[connection.macDeviceId]?.name ?? "Mac"
    }

    private var deviceIcon: String {
        "desktopcomputer"
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
