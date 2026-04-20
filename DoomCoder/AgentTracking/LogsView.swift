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
        case notifications = "🔔"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .all
    @State private var events: [EventStore.Row] = []
    @State private var notifications: [EventStore.NotificationRow] = []
    @State private var expandedID: Int64? = nil
    @State private var totalCount: Int = 0
    @State private var retentionDays: Int = EventStore.retentionDays
    @State private var tick = 0
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if filter == .notifications {
                notificationsList
            } else {
                eventsList
            }
            Divider()
            footerBar
        }
        .onAppear { reload() }
        .onReceive(refreshTimer) { _ in tick &+= 1; reload() }
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
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, let payload = row.payload {
                payloadDetail(payload)
            }
        }
        .background(isExpanded ? Color.accentColor.opacity(0.04) : Color.clear)
    }

    private func payloadDetail(_ json: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: true) {
                Text(prettyJSON(json))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 200)
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prettyJSON(json), forType: .string)
                } label: {
                    Label("Copy JSON", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
        case "claude":     return .orange
        case "cursor":     return .blue
        case "vscode":     return .purple
        case "copilotcli": return .green
        default:           return .gray
        }
    }

    private func formattedDate(_ ts: TimeInterval) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: Date(timeIntervalSince1970: ts))
    }

    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8)
        else { return raw }
        return str
    }

    private func reload() {
        let agentKey: String?
        switch filter {
        case .all:            agentKey = nil
        case .claude:         agentKey = TrackedAgent.claude.rawValue
        case .cursor:         agentKey = TrackedAgent.cursor.rawValue
        case .vscode:         agentKey = TrackedAgent.vscode.rawValue
        case .copilot:        agentKey = TrackedAgent.copilotCLI.rawValue
        case .notifications:  agentKey = nil
        }
        if filter == .notifications {
            notifications = EventStore.shared.recentNotifications()
        } else if let agentKey {
            events = EventStore.shared.recent(agent: agentKey)
        } else {
            events = EventStore.shared.recent()
        }
        totalCount = EventStore.shared.count(agent: agentKey)
    }

    private func exportJSON() {
        let agentKey: String?
        switch filter {
        case .claude:  agentKey = TrackedAgent.claude.rawValue
        case .cursor:  agentKey = TrackedAgent.cursor.rawValue
        case .vscode:  agentKey = TrackedAgent.vscode.rawValue
        case .copilot: agentKey = TrackedAgent.copilotCLI.rawValue
        default:       agentKey = nil
        }
        guard let data = EventStore.shared.exportJSON(agent: agentKey) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "doomcoder-events.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func exportCSV() {
        let agentKey: String?
        switch filter {
        case .claude:  agentKey = TrackedAgent.claude.rawValue
        case .cursor:  agentKey = TrackedAgent.cursor.rawValue
        case .vscode:  agentKey = TrackedAgent.vscode.rawValue
        case .copilot: agentKey = TrackedAgent.copilotCLI.rawValue
        default:       agentKey = nil
        }
        let csv = EventStore.shared.exportCSV(agent: agentKey)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "doomcoder-events.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
