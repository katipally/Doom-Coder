// PendingBadge.swift — Companion
// Tiny yellow dot that appears next to a setting while an iOS->Mac
// round-trip is in flight (>2s). Turns red on nack / timeout. Auto-clears
// on success. Driven by SettingsSyncStatus.

import SwiftUI

struct PendingBadge: View {
    @State private var status = SettingsSyncStatus.shared
    @State private var visible = false
    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let err = status.lastErrorText, !status.pending {
                badge(color: .red, symbol: "exclamationmark.circle.fill", help: err)
            } else if visible {
                badge(color: .yellow, symbol: "circle.fill", help: "Sync in progress…")
            } else {
                EmptyView()
            }
        }
        .onReceive(pollTimer) { _ in
            guard let since = status.pendingSince else { visible = false; return }
            visible = Int(Date().timeIntervalSince(since) * 1000) >= status.visibilityThresholdMs
        }
    }

    private func badge(color: Color, symbol: String, help: String) -> some View {
        Image(systemName: symbol)
            .font(.caption2)
            .foregroundStyle(color)
            .help(help)
            .transition(.scale.combined(with: .opacity))
    }
}
