import SwiftUI

// Browsable event log with per-agent filtering, notification history,
// expandable JSON payloads, and export to JSON/CSV.
struct LogsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case claude = "Claude"
        case cursor = "Cursor"
        case vscode = "VS Code"
        case copilot = "Copilot"
        case windsurf = "Windsurf"
        case codex = "Codex"
        case notifications = "🔔"
        case sessions = "Sessions"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .all
    @State private var events: [EventStore.Row] = []
    @State private var notifications: [EventStore.NotificationRow] = []
    @State private var sessionHistory: [EventStore.SessionHistoryEntry] = []
    @State private var selectedSession: EventStore.SessionHistoryEntry? = nil
    @State private var expandedID: Int64? = nil
    @State private var totalCount: Int = 0
    @State private var retentionDays: Int = EventStore.retentionDays

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if filter == .notifications {
                notificationsList
            } else if filter == .sessions {
                sessionHistoryList
            } else {
                eventsList
            }
            Divider()
            footerBar
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .doomcoderNewEvent)) { _ in reload() }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Filter.allCases) { f in
                    Button {
                        filter = f
                        reload()
                    } label: {
                        Text(f.rawValue)
                            .font(.caption.weight(filter == f ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                filter == f ? Color.accentColor.opacity(0.15) : Color.clear,
                                in: Capsule()
                            )
                            .foregroundStyle(filter == f ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Events List

    private var eventsList: some View {
        Group {
            if events.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("No events yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(events) { row in
                            eventRow(row)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ row: EventStore.Row) -> some View {
        let isExpanded = expandedID == row.id
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DCAnim.micro) {
                    expandedID = isExpanded ? nil : row.id
                }
            } label: {
                HStack(spacing: 8) {
                    agentBadge(row.agent)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(row.event)
                                .font(.caption.weight(.medium))
                            if let tool = row.tool {
                                Text("· \(tool)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text(formattedDate(row.ts))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if row.payload != nil {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded, let payload = row.payload {
                PayloadRendererView(json: payload)
            }
        }
        .background(isExpanded ? Color.accentColor.opacity(0.04) : Color.clear)
    }

    // MARK: - Notifications List

    private var notificationsList: some View {
        Group {
            if notifications.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bell.slash")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("No notifications sent yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(notifications) { row in
                            notificationRow(row)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func notificationRow(_ row: EventStore.NotificationRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(row.success ? .green : .red)
            agentBadge(row.agent)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.caption.weight(.medium))
                Text(row.body)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(row.channel)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.1), in: Capsule())
            Text(formattedDate(row.ts))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Session History List

    private var sessionHistoryList: some View {
        Group {
            if sessionHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No session history yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Completed agent sessions will appear here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(sessionHistory) { entry in
                    Button {
                        selectedSession = entry
                    } label: {
                        HStack(spacing: 10) {
                            agentBadge(entry.agent)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(TrackedAgent(rawValue: entry.agent)?.displayName ?? entry.agent)
                                        .font(.caption.weight(.semibold))
                                    outcomeBadge(entry.outcome)
                                }
                                Text("\(durationString(entry.durationSeconds)) · \(entry.toolCount) tools · started \(entry.startedAt, style: .relative) ago")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(shortDate(entry.endedAt))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .sheet(item: $selectedSession) { entry in
                    SessionDetailSheet(entry: entry)
                }
            }
        }
    }

    private func outcomeBadge(_ outcome: String) -> some View {
        let color: Color = outcome == "completed" ? .green : outcome == "failed" ? .red : .secondary
        return Text(outcome)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    private func shortDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { retentionDays },
                set: { v in
                    retentionDays = v
                    EventStore.retentionDays = v
                    EventStore.shared.purgeOld()
                    reload()
                }
            )) {
                Text("1 day").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            .pickerStyle(.menu)
            .frame(width: 90)
            .controlSize(.small)

            Text("\(totalCount) events")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                exportJSON()
            } label: {
                Label("JSON", systemImage: "arrow.down.doc")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Button {
                exportCSV()
            } label: {
                Label("CSV", systemImage: "tablecells")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Button("Clear All") {
                EventStore.shared.clearAll()
                reload()
            }
            .font(.caption2)
            .foregroundStyle(.red)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func agentBadge(_ agent: String) -> some View {
        let ta = TrackedAgent(rawValue: agent)
        let color = agentColor(agent)
        return Group {
            if let ta {
                Image(nsImage: AgentIconProvider.icon(for: ta, size: 16))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
        }
    }

    private func agentColor(_ agent: String) -> Color {
        switch agent.lowercased() {
        case "claude":      return .orange
        case "cursor":      return .blue
        case "vscode":      return .purple
        case "copilot_cli": return .green
        case "windsurf":    return Color(red: 0, green: 0.67, blue: 1)
        case "codex_cli":   return Color(red: 0.4, green: 0.2, blue: 1.0)
        default:            return .gray
        }
    }

    private func formattedDate(_ ts: TimeInterval) -> String {
        Self.dateFmt.string(from: Date(timeIntervalSince1970: ts))
    }

    private func agentKey(for f: Filter) -> String? {
        switch f {
        case .claude:        return TrackedAgent.claude.rawValue
        case .cursor:        return TrackedAgent.cursor.rawValue
        case .vscode:        return TrackedAgent.vscode.rawValue
        case .copilot:       return TrackedAgent.copilotCLI.rawValue
        case .windsurf:      return TrackedAgent.windsurf.rawValue
        case .codex:         return TrackedAgent.codexCLI.rawValue
        case .all, .notifications, .sessions: return nil
        }
    }

    private func reload() {
        let key = agentKey(for: filter)
        if filter == .notifications {
            notifications = EventStore.shared.recentNotifications()
        } else if filter == .sessions {
            sessionHistory = EventStore.shared.recentSessionHistory(agent: nil)
        } else if let key {
            events = EventStore.shared.recent(agent: key)
        } else {
            events = EventStore.shared.recent()
        }
        totalCount = EventStore.shared.count(agent: key)
    }

    private func exportJSON() {
        guard let data = EventStore.shared.exportJSON(agent: agentKey(for: filter)) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "doomcoder-events.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func exportCSV() {
        let csv = EventStore.shared.exportCSV(agent: agentKey(for: filter))
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "doomcoder-events.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Session detail sheet

private struct SessionDetailSheet: View {
    let entry: EventStore.SessionHistoryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var sessionEvents: [EventStore.Row] = []
    @State private var expandedEventID: Int64? = nil

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(TrackedAgent(rawValue: entry.agent)?.displayName ?? entry.agent)
                            .font(.headline)
                        outcomePill(entry.outcome)
                    }
                    Text("\(Self.timeFmt.string(from: entry.startedAt)) – \(Self.timeFmt.string(from: entry.endedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(summaryStat)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // Event list
            if sessionEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No events recorded for this session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Text("Events (\(sessionEvents.count))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        Divider()
                        ForEach(sessionEvents) { ev in
                            eventRow(ev)
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear {
            sessionEvents = EventStore.shared.events(forSessionKey: entry.sessionKey)
        }
    }

    @ViewBuilder
    private func eventRow(_ ev: EventStore.Row) -> some View {
        let isExpanded = expandedEventID == ev.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(Self.timeFmt.string(from: Date(timeIntervalSince1970: ev.ts)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 58, alignment: .leading)
                phaseIcon(ev.state)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ev.event)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if let tool = ev.tool {
                        Text(tool)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if ev.payload != nil {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                if ev.payload != nil {
                    withAnimation(.easeOut(duration: 0.15)) {
                        expandedEventID = isExpanded ? nil : ev.id
                    }
                }
            }

            if isExpanded, let payload = ev.payload {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(prettyJSON(payload) ?? payload)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                .background(Color.secondary.opacity(0.06))
            }
        }
    }

    private func phaseIcon(_ state: String?) -> some View {
        let (sym, col): (String, Color) = {
            switch state {
            case "running", "toolStart":        return ("play.fill", .green)
            case "toolEnd":                     return ("checkmark.circle", .secondary)
            case "toolError", "error":          return ("exclamationmark.triangle", .red)
            case "permissionNeeded":            return ("hand.raised", .orange)
            case "sessionStart":                return ("circle", .accentColor)
            case "sessionEnd", "completed":     return ("checkmark.circle.fill", .green)
            case "agentResponse", "waitingInput": return ("ellipsis.circle", .yellow)
            default:                            return ("circle.dotted", .secondary)
            }
        }()
        return Image(systemName: sym)
            .font(.caption2)
            .foregroundStyle(col)
            .frame(width: 14)
            .accessibilityHidden(true)
    }

    private func outcomePill(_ outcome: String) -> some View {
        let color: Color = outcome == "completed" ? .green : outcome == "failed" ? .red : .secondary
        return Text(outcome)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    private var summaryStat: String {
        var parts: [String] = []
        let s = Int(entry.durationSeconds)
        if s < 60 { parts.append("\(s)s") }
        else if s < 3600 { parts.append("\(s/60)m \(s%60)s") }
        else { parts.append("\(s/3600)h \((s%3600)/60)m") }
        if entry.toolCount > 0 { parts.append("\(entry.toolCount) tools") }
        if entry.permissionCount > 0 { parts.append("\(entry.permissionCount) approvals") }
        if entry.subagentCount > 0 { parts.append("\(entry.subagentCount) sub-agents") }
        return parts.joined(separator: " · ")
    }

    private func prettyJSON(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}
