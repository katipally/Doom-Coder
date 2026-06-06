// DiscoverableDeviceSubscription.swift — DoomCoder Mac
//
// v6.1: the Mac's Add-Device "Same iCloud" picker is fed directly by the
// PeerStatus heartbeats the Mac ALREADY receives through the shared private
// zone (same Apple ID = one private database). This replaces the old
// public-DB CKQuery, which failed with "Field 'recordName' is not marked
// queryable" (TRUEPREDICATE needs a queryable recordName index that doesn't
// exist by default) — and is faster, since PeerStatus arrives via the sync
// engine with no extra round-trip.
//
// `noteSeen` is called from `CloudKitPusher.ingestPeerStatus` for every
// same-iCloud iPhone (shareURLString == nil) — including currently
// disconnected (suppressed) devices, so the user can always re-connect them
// from the picker.

import Foundation
import OSLog
import DoomCoderCore

@MainActor
final class DiscoverableDeviceSubscription: ObservableObject {
    static let shared = DiscoverableDeviceSubscription()

    private let logger = Logger(subsystem: "com.doomcoder", category: "discoverable.device.mac")

    /// Same-iCloud iPhones the Mac has heard from, sorted by lastSeen desc.
    @Published private(set) var devices: [DiscoverableDeviceRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private var byId: [String: DiscoverableDeviceRecord] = [:]
    /// Show iPhones seen within this window. Generous because PeerStatus is
    /// event-driven (+ a foreground heartbeat), not a tight poll.
    private let staleWindow: TimeInterval = 30 * 60

    private init() {}

    func start() async { rebuild() }

    /// Manual refresh = force a CloudKit fetch (delivers fresh PeerStatus →
    /// `noteSeen`) then re-prune. Drives the picker's Refresh button.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        CloudKitPusher.shared.forceFetch()
        try? await Task.sleep(nanoseconds: 700_000_000)
        rebuild()
    }

    /// Called from `CloudKitPusher.ingestPeerStatus` for SAME-iCloud iPhones.
    func noteSeen(iosDeviceId: String, name: String, model: String,
                  systemVersion: String, lastSeen: Date) {
        guard !iosDeviceId.isEmpty else { return }
        byId[iosDeviceId] = DiscoverableDeviceRecord(
            iosDeviceId: iosDeviceId,
            name: name,
            model: model,
            systemVersion: systemVersion,
            lastSeen: lastSeen,
            publishedBy: ""
        )
        rebuild()
    }

    private func rebuild() {
        let cutoff = Date().addingTimeInterval(-staleWindow)
        devices = byId.values
            .filter { $0.lastSeen >= cutoff }
            .sorted { $0.lastSeen > $1.lastSeen }
    }
}
