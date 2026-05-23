// SyncDiagnosticsView.swift — Companion
// Live tail of SyncTelemetry events plus a Force Re-sync button. Surfaced
// from SettingsView so the user can confirm iOS→Mac round-trips in real
// time. Mirrors the Mac-side diagnostics view 1:1.

import SwiftUI
import DoomCoderCore

struct SyncDiagnosticsView: View {

    @State private var events: [SyncEvent] = SyncTelemetry.shared.snapshot()
    @State private var sync = CompanionSyncEngine.shared
    @State private var lastLatencyMs: Int? = SyncTelemetry.shared.lastRoundTripLatencyMs()

    private let eventStream = NotificationCenter.default
        .publisher(for: SyncTelemetry.eventRecordedNotification)
    private let rtStream = NotificationCenter.default
        .publisher(for: SyncTelemetry.roundTripCompletedNotification)

    var body: some View {
        List {
            summarySection
            actionsSection
            eventsSection
        }
        .navigationTitle("Sync Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(eventStream) { _ in
            events = SyncTelemetry.shared.snapshot()
        }
        .onReceive(rtStream) { note in
            if let ms = note.userInfo?["latencyMs"] as? Int { lastLatencyMs = ms }
        }
    }

    private var summarySection: some View {
        Section("Status") {
            row("CloudKit account",
                sync.accountAvailable ? "Available" : "Unavailable",
                tint: sync.accountAvailable ? .green : .orange)
            row("Zone ready", sync.zoneReady ? "Yes" : "No",
                tint: sync.zoneReady ? .green : .secondary)
            row("Last sync",
                sync.lastSyncAt.map { Self.fmt.localizedString(for: $0, relativeTo: Date()) } ?? "Never",
                tint: .secondary)
            if let ms = lastLatencyMs {
                row("Last round-trip", "\(ms) ms",
                    tint: ms < 4_000 ? .green : (ms < 10_000 ? .orange : .red))
            } else {
                row("Last round-trip", "—", tint: .secondary)
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task { await sync.fetchChanges() }
            } label: {
                Label("Force re-sync now", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                SyncTelemetry.shared.clear()
                events = []
                lastLatencyMs = nil
            } label: {
                Label("Clear event log", systemImage: "trash")
            }
            Button(role: .destructive) {
                Task { await sync.resetLocalSyncState() }
            } label: {
                Label("Reset local sync state", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            }
        } footer: {
            Text("Reset clears this device's CKSyncEngine state and cached server records, then re-bootstraps. Use if iOS→Mac changes stop landing. Server data is untouched.")
                .font(.caption2)
        }
    }

    private var eventsSection: some View {
        Section("Recent events (\(events.count))") {
            if events.isEmpty {
                Text("No sync events yet.").foregroundStyle(.secondary)
            } else {
                ForEach(events.reversed()) { ev in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(for: ev.kind))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(ev.kind.rawValue)
                                    .font(.callout.weight(.medium))
                                Text("[\(ev.side.rawValue)]")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let rt = ev.recordType {
                                    Text(rt)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let ms = ev.latencyMs {
                                    Text("\(ms) ms")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(ms < 4_000 ? .green : .orange)
                                }
                            }
                            Text(Self.timeFmt.string(from: ev.timestamp))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if let d = ev.detail, !d.isEmpty {
                                Text(d).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String, tint: Color) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(tint).font(.callout.monospacedDigit())
        }
    }

    private func color(for kind: SyncEventKind) -> Color {
        switch kind {
        case .localEdit, .enqueued, .sent: return .blue
        case .pushReceived, .fetched:      return .indigo
        case .applied, .roundTripCompleted: return .green
        case .nacked, .engineError:         return .red
        case .stateUpdate:                  return .gray
        }
    }

    private static let fmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
