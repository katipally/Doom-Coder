// SessionsView.swift — DoomCoder Companion
// Displays live AI-agent sessions in a list and provides a detail drill-down.
// A 5 s foreground backstop calls fetchChanges() while the view is visible.

import SwiftUI
import DoomCoderCore

struct SessionsView: View {

    @State private var sessionStore  = SessionStore.shared
    @State private var notifStore    = NotificationLogStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if sessionStore.live.isEmpty {
                    ContentUnavailableView(
                        "No Active Sessions",
                        systemImage: "waveform.path.ecg",
                        description: Text("Start a coding session on your Mac to see it here.")
                    )
                } else {
                    List(sessionStore.live, id: \.sessionKey) { session in
                        NavigationLink(value: session) {
                            SessionTile(session: session)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: SessionRecord.self) { session in
                SessionDetailView(session: session)
            }
        }
        .task {
            // Fetch every 30 s while foregrounded on this tab as a backstop.
            // Real-time updates arrive via CKDatabaseSubscription silent push.
            while !Task.isCancelled {
                await CompanionSyncEngine.shared.fetchChanges()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

// MARK: - SessionTile

private struct SessionTile: View {
    let session: SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(TrackedAgent(rawValue: session.agent)?.displayName ?? session.agent)
                    .font(.headline)
                Spacer()
                if session.awaitingPermission {
                    Label("Needs you", systemImage: "hand.raised.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
            if let base = session.cwdBase {
                Text(base)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Label("\(session.toolCallCount) tools", systemImage: "hammer")
                if session.errorCount > 0 {
                    Label("\(session.errorCount) err", systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                }
                Spacer()
                Text(session.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - SessionDetailView

struct SessionDetailView: View {

    let session: SessionRecord

    // NOTE: We reuse NotificationLogStore for per-session event timeline rather
    // than maintaining a separate EventStore (deferred to v1.1 when EventRecord
    // volume may warrant its own store).
    @State private var notifStore = NotificationLogStore.shared

    private var relatedEntries: [NotificationLogRecord] {
        notifStore.entries
            .filter { $0.sessionKey == session.sessionKey }
    }

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("Agent", value: TrackedAgent(rawValue: session.agent)?.displayName ?? session.agent)
                LabeledContent("State", value: session.displayState)
                if let base = session.cwdBase {
                    LabeledContent("Directory", value: base)
                }
                LabeledContent("Started", value: session.startedAt, format: .dateTime)
                LabeledContent("Tools", value: "\(session.toolCallCount)")
                LabeledContent("Errors", value: "\(session.errorCount)")
                if session.awaitingPermission {
                    Label("Awaiting your permission", systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("Timeline (\(relatedEntries.count))") {
                if relatedEntries.isEmpty {
                    Text("No events synced yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(relatedEntries, id: \.notifId) { entry in
                        EventRow(entry: entry)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(session.cwdBase ?? session.agent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                await CompanionSyncEngine.shared.fetchChanges()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

// MARK: - EventRow

private struct EventRow: View {
    let entry: NotificationLogRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                phaseLabel
                Spacer()
                Text(entry.ts, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(entry.body)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var phaseLabel: some View {
        let phase = NormalizedEventPhase(rawValue: entry.phase) ?? .other
        let color: Color = {
            switch phase {
            case .error, .toolError: return .red
            case .permissionNeeded:  return .orange
            case .sessionEnd:        return .green
            case .sessionStart:      return .blue
            default:                 return .secondary
            }
        }()
        return Text(entry.phase)
            .font(.caption.bold())
            .foregroundStyle(color)
    }
}
