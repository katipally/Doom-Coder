// EmptyStateView.swift — DoomCoder Companion
// Read-only empty state for the Dashboard / Agent list when no Mac data has
// arrived yet. No connect button — the iOS app is read-only and data appears
// automatically once the Mac publishes.

import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("No Agents Yet")
                    .font(.title3.bold())
                Text("Open DoomCoder on your Mac and sign in to the same iCloud account. Agents and notifications will appear here automatically.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 32)
        .listRowBackground(Color.clear)
    }
}
