// LogsView.swift — DoomCoder Companion
// Searchable, filterable log browser for the notification history.
// Supports agent filter chips, phase filter chips, and time-window selection.

import SwiftUI
import DoomCoderCore

struct LogsView: View {

    @State private var notifStore = NotificationLogStore.shared
    @State private var segment: Segment = .notifications
    @State private var searchText  = ""
    @State private var agentFilter: TrackedAgent? = nil
    @State private var phaseFilter: NormalizedEventPhase? = nil
    @State private var windowFilter: TimeWindow = .all

    enum Segment: String, CaseIterable { case notifications = "Notifications"; case events = "Events" }
    enum TimeWindow: String, CaseIterable { case hour = "1h"; case day = "24h"; case week = "7d"; case all = "All" }

    private var filtered: [NotificationLogRecord] {
        let cutoff: Date? = {
            switch windowFilter {
            case .hour:  return Date(timeIntervalSinceNow: -3_600)
            case .day:   return Date(timeIntervalSinceNow: -86_400)
            case .week:  return Date(timeIntervalSinceNow: -604_800)
            case .all:   return nil
            }
        }()
        return notifStore.entries.filter { entry in
            if let cut = cutoff, entry.ts < cut { return false }
            if let a = agentFilter, entry.agent != a.rawValue { return false }
            if let p = phaseFilter, entry.phase != p.rawValue { return false }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                guard entry.title.lowercased().contains(q)
                   || entry.body.lowercased().contains(q)
                   || entry.agent.lowercased().contains(q)
                else { return false }
            }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                segmentedControl
                filterChips
                logList
            }
            .navigationTitle("Logs")
            .searchable(text: $searchText, prompt: "Search logs")
        }
    }

    // MARK: - Subviews

    private var segmentedControl: some View {
        Picker("View", selection: $segment) {
            ForEach(Segment.allCases, id: \.self) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .padding([.horizontal, .top])
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Time window
                ForEach(TimeWindow.allCases, id: \.self) { w in
                    FilterChip(label: w.rawValue, active: windowFilter == w) {
                        windowFilter = w
                    }
                }
                Divider().frame(height: 24)
                // Agent filter
                ForEach(TrackedAgent.allCases, id: \.rawValue) { agent in
                    FilterChip(label: agent.displayName, active: agentFilter == agent) {
                        agentFilter = agentFilter == agent ? nil : agent
                    }
                }
                Divider().frame(height: 24)
                // Phase filter (show only the most actionable phases to keep chips manageable)
                ForEach([NormalizedEventPhase.sessionStart,
                         .sessionEnd, .error, .permissionNeeded, .toolError], id: \.rawValue) { phase in
                    FilterChip(label: phase.rawValue, active: phaseFilter == phase) {
                        phaseFilter = phaseFilter == phase ? nil : phase
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var logList: some View {
        Group {
            if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText.isEmpty ? "logs" : searchText)
            } else {
                List(filtered, id: \.notifId) { entry in
                    LogEntryRow(entry: entry)
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - FilterChip

private struct FilterChip: View {
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(active ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - LogEntryRow

private struct LogEntryRow: View {
    let entry: NotificationLogRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                Text(entry.ts, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(entry.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(TrackedAgent(rawValue: entry.agent)?.displayName ?? entry.agent)
                Text("·")
                Text(entry.phase)
                if let mac = Optional(entry.macName), !mac.isEmpty {
                    Text("·")
                    Text(mac)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
