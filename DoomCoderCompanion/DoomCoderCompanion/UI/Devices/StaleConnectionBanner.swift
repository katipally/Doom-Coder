// StaleConnectionBanner.swift — DoomCoder Companion
// v5: a small banner above the devices list that surfaces:
//   • a "Mac offline" or "iPhone offline" hint when a Connection
//     has been .suspended for >5 minutes (CloudKit hasn't seen a
//     heart-beat from the other side).
//   • a "Re-pair" CTA pointing to the most-recent tombstoned
//     Connection (status == .removed) so the user can quickly
//     re-add a device they previously disconnected.
//
// Hidden when all Connections are .active. Shown in the iOS
// Dashboard tab between the page title and the DevicesSection
// so the user notices it without scrolling.

import SwiftUI
import DoomCoderCore

struct StaleConnectionBanner: View {
    let store: ConnectionStore
    @State private var showingAddMac = false
    @State private var prepopulatedLink: String? = nil

    var body: some View {
        Group {
            if let tombstone = store.mostRecentTombstoned {
                banner(
                    title: tombstoneDisplayName(for: tombstone),
                    message: "You removed this Mac. Re-pair to bring it back?",
                    actionLabel: "Re-pair",
                    action: { prepopulatedLink = tombstone.ckShareRef?.shareURLString; showingAddMac = true },
                    tint: .blue
                )
            } else if store.hasInactiveConnection {
                banner(
                    title: "Some devices are offline",
                    message: "Pull to refresh, or open a Mac and make sure DoomCoder is running.",
                    actionLabel: nil,
                    action: nil,
                    tint: .orange
                )
            }
        }
        .sheet(isPresented: $showingAddMac) {
            AddMacView()
        }
    }

    @ViewBuilder
    private func banner(
        title: String,
        message: String,
        actionLabel: String?,
        action: (() -> Void)?,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.3), lineWidth: 0.5)
        )
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
    }

    private func tombstoneDisplayName(for tombstone: Connection) -> String {
        // The iOS side knows its own display name; for the Mac
        // we look up the most-recently-seen MacStatus. The
        // tombstone's macDeviceId is the same as the original
        // row's, so the lookup works.
        if let name = MacStatusStore.shared.byMacId[tombstone.macDeviceId]?.name, !name.isEmpty {
            return name
        }
        return "Previous Mac"
    }
}
