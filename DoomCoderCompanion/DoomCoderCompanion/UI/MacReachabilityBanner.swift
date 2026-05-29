// MacReachabilityBanner.swift — DoomCoder Companion
// Shown when a Mac is connected (primary != nil) but its heartbeat is older
// than the staleness threshold. Tells the user the data they are seeing may
// not be current and offers a manual refresh. The Mac side heartbeats every
// 60 seconds, so 3 minutes is "two missed heartbeats" — a conservative
// signal that something is wrong (Mac sleeping, app quit, network down, or
// iCloud push throttling).
//
// Dynamic and adaptive: the threshold is purely time-based and works for any
// Mac the user pairs with. No hardcoded names or IDs.

import SwiftUI
import DoomCoderCore

@MainActor
struct MacReachabilityBanner: View {
    @State private var macStore = MacStatusStore.shared
    @State private var engine = CompanionSyncEngine.shared
    @State private var isRefreshing = false
    @State private var now = Date()

    /// Threshold after which we surface a warning. Mac heartbeats every 60s.
    private let staleAfter: TimeInterval = 180

    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let mac = macStore.primary,
               let level = staleness(for: mac) {
                banner(for: mac, level: level)
            }
        }
        .onReceive(timer) { now = $0 }
    }

    // MARK: - Staleness classification

    private enum Level { case stale, offline }

    private func staleness(for mac: MacStatusRecord) -> Level? {
        let age = now.timeIntervalSince(mac.lastSeen)
        if age >= 600 { return .offline }
        if age >= staleAfter { return .stale }
        return nil
    }

    // MARK: - Banner

    @ViewBuilder
    private func banner(for mac: MacStatusRecord, level: Level) -> some View {
        let tint: Color = (level == .offline) ? .red : .orange
        let symbol = (level == .offline) ? "wifi.exclamationmark" : "exclamationmark.triangle.fill"
        let title = (level == .offline) ? "\(mac.name) not reachable" : "\(mac.name) may be out of date"
        let detail = (level == .offline)
            ? "We haven't heard from your Mac in over 10 minutes. Open DoomCoder on your Mac, or check your network and iCloud sign-in. New data and notifications won't arrive until it reconnects."
            : "Last sync was \(relativeAge(mac.lastSeen)). The status below may not reflect what's happening on your Mac right now."

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        HStack(spacing: 6) {
                            if isRefreshing {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isRefreshing ? "Refreshing" : "Try again")
                        }
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRefreshing)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Helpers

    private func refresh() async {
        isRefreshing = true
        // When the Mac is in .offline state, the stale heartbeat was already seen
        // by the sync engine. An incremental fetchChanges() won't return it. Use
        // forceFetchAll() to wipe the token and do a fresh full fetch so that the
        // Mac's latest record is retrieved even if it hasn't changed since our last
        // sync. For .stale (3-10 min), incremental fetch is sufficient.
        if let mac = macStore.primary, staleness(for: mac) == .offline {
            await engine.forceFetchAll()
        } else {
            await engine.fetchChanges()
        }
        now = Date()
        isRefreshing = false
    }

    private func relativeAge(_ date: Date) -> String {
        let secs = Int(now.timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60) minutes ago" }
        if secs < 86400 { return "\(secs / 3600) hours ago" }
        return "\(secs / 86400) days ago"
    }
}
