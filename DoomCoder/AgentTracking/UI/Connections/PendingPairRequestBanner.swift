// PendingPairRequestBanner.swift — DoomCoder Mac
// v5.1: surfaces any pending same-iCloud pair requests as a
// banner above the Devices list. Tapping opens a sheet that
// lets the user Allow or Deny. The banner is hidden when the
// queue is empty.

import SwiftUI
import DoomCoderCore

struct PendingPairRequestBanner: View {
    @ObservedObject var queue: PendingPairRequestQueue
    let onAllow: (PendingPairRequestQueue.Request) async -> Void
    let onDeny: (PendingPairRequestQueue.Request) async -> Void
    @State private var selected: PendingPairRequestQueue.Request?
    @State private var working: Set<String> = []

    var body: some View {
        if let first = queue.requests.first {
            HStack(spacing: 12) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iPhone wants to pair")
                        .font(.subheadline.weight(.semibold))
                    if queue.requests.count > 1 {
                        Text("\(queue.requests.count) pending requests")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Tap to review and approve.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if working.contains(first.id) {
                    ProgressView().controlSize(.small)
                }
                Button("Review") { selected = first }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(12)
            .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.blue.opacity(0.3), lineWidth: 0.5)
            )
            .sheet(item: $selected) { req in
                PendingPairRequestSheet(
                    request: req,
                    onAllow: {
                        working.insert(req.id)
                        await onAllow(req)
                        working.remove(req.id)
                        selected = nil
                    },
                    onDeny: {
                        working.insert(req.id)
                        await onDeny(req)
                        working.remove(req.id)
                        selected = nil
                    }
                )
            }
        }
    }
}
