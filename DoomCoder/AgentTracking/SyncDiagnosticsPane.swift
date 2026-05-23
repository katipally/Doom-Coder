import SwiftUI
import DoomCoderCore

// Mac-side mirror of the Companion's SyncDiagnosticsView. Live tail of
// SyncTelemetry plus account/zone status and a Force re-sync button so
// the user can verify round-trips without leaving the Mac app.
struct SyncDiagnosticsPane: View {

    @State private var events: [SyncEvent] = SyncTelemetry.shared.snapshot()
    @State private var lastLatencyMs: Int? = SyncTelemetry.shared.lastRoundTripLatencyMs()
    @State private var engine = CloudKitSyncEngine.shared

    private let eventStream = NotificationCenter.default
        .publisher(for: SyncTelemetry.eventRecordedNotification)
    private let rtStream = NotificationCenter.default
        .publisher(for: SyncTelemetry.roundTripCompletedNotification)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            list
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(eventStream) { _ in events = SyncTelemetry.shared.snapshot() }
        .onReceive(rtStream) { note in
            if let ms = note.userInfo?["latencyMs"] as? Int { lastLatencyMs = ms }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sync Diagnostics").font(.title2.weight(.semibold))
                Spacer()
                Button {
                    Task { await engine.fetchChanges() }
                } label: {
                    Label("Force re-sync", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    SyncTelemetry.shared.clear()
                    events = []
                    lastLatencyMs = nil
                } label: {
                    Label("Clear log", systemImage: "trash")
                }
            }
            HStack(spacing: 16) {
                statusPill(label: "CloudKit",
                           value: engine.isAvailable ? "Available" : "Unavailable",
                           tint: engine.isAvailable ? .green : .orange)
                statusPill(label: "Last sync",
                           value: engine.lastSyncAt.map { Self.fmt.localizedString(for: $0, relativeTo: Date()) } ?? "Never",
                           tint: .secondary)
                if let ms = lastLatencyMs {
                    statusPill(label: "Round-trip",
                               value: "\(ms) ms",
                               tint: ms < 4_000 ? .green : (ms < 10_000 ? .orange : .red))
                }
                if let err = engine.lastError {
                    statusPill(label: "Error", value: err, tint: .red)
                }
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if events.isEmpty {
                    Text("No sync events yet.").foregroundStyle(.secondary).padding(.top, 24)
                } else {
                    ForEach(events.reversed()) { ev in
                        HStack(spacing: 8) {
                            Circle().fill(color(for: ev.kind)).frame(width: 8, height: 8)
                            Text(Self.timeFmt.string(from: ev.timestamp))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 100, alignment: .leading)
                            Text(ev.kind.rawValue).font(.callout.weight(.medium))
                            Text("[\(ev.side.rawValue)]").font(.caption2).foregroundStyle(.secondary)
                            if let rt = ev.recordType {
                                Text(rt).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let ms = ev.latencyMs {
                                Text("\(ms) ms")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(ms < 4_000 ? .green : .orange)
                            }
                            if let d = ev.detail, !d.isEmpty {
                                Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                        Divider().opacity(0.3)
                    }
                }
            }
            .padding(.trailing, 8)
        }
    }

    private func statusPill(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(tint).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
