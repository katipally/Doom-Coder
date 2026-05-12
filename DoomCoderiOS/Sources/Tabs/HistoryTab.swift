import SwiftUI

struct HistoryTab: View {
    @EnvironmentObject var store: SessionStore
    @State private var search: String = ""
    @State private var filter: AgentFilter = .all

    enum AgentFilter: String, CaseIterable, Identifiable {
        case all, claude, cursor, vscode, copilotCLI, codexCLI, windsurf
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all:        return "All"
            case .claude:     return "Claude"
            case .cursor:     return "Cursor"
            case .vscode:     return "VS Code"
            case .copilotCLI: return "Copilot CLI"
            case .codexCLI:   return "Codex CLI"
            case .windsurf:   return "Windsurf"
            }
        }

        // Raw values that TrackedAgent uses for these agents.
        var trackedAgentRawValues: [String] {
            switch self {
            case .all:        return []
            case .claude:     return ["claude"]
            case .cursor:     return ["cursor"]
            case .vscode:     return ["vscode"]
            case .copilotCLI: return ["copilot_cli"]
            case .codexCLI:   return ["codex_cli"]
            case .windsurf:   return ["windsurf"]
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(white: 0.06), Color(white: 0.02)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                list
            }
            .navigationTitle("History")
            .searchable(text: $search, prompt: "Search sessions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(AgentFilter.allCases) { f in
                            Button(f.displayName) { filter = f }
                        }
                    } label: {
                        Image(systemName: filter == .all
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .task { await refresh() }
        }
    }

    @ViewBuilder private var list: some View {
        if filteredRows.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "clock.badge.xmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("No history yet").font(.title3.bold())
                Text("Older than 7 days is auto-pruned.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(grouped, id: \.0) { (day, rows) in
                    Section(header: Text(day).foregroundStyle(.secondary)) {
                        ForEach(rows) { row in
                            NavigationLink(value: row.id) { row.cellView }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await refresh() }
            .navigationDestination(for: String.self) { key in SessionDetailView(sessionKey: key) }
        }
    }

    private var filteredRows: [SessionStore.SessionRow] {
        store.history.filter { row in
            let matchesAgent = filter == .all ||
                filter.trackedAgentRawValues.contains(row.agent.lowercased())
            let matchesSearch = search.isEmpty ||
                row.cwdBasename.localizedCaseInsensitiveContains(search) ||
                row.agent.localizedCaseInsensitiveContains(search) ||
                (row.currentTool?.localizedCaseInsensitiveContains(search) ?? false) ||
                (row.promptPreview?.localizedCaseInsensitiveContains(search) ?? false)
            return matchesAgent && matchesSearch
        }
    }

    private var grouped: [(String, [SessionStore.SessionRow])] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        let groups = Dictionary(grouping: filteredRows) { row -> String in
            if cal.isDateInToday(row.lastEventAt) { return "Today" }
            if cal.isDateInYesterday(row.lastEventAt) { return "Yesterday" }
            return fmt.string(from: row.lastEventAt)
        }
        return groups.sorted { lhs, rhs in
            (lhs.value.first?.lastEventAt ?? .distantPast) > (rhs.value.first?.lastEventAt ?? .distantPast)
        }.map { ($0.key, $0.value) }
    }

    private func refresh() async {
        do {
            let rows = try await CloudKitClient.shared.fetchHistory(daysBack: IOSUserSettings.shared.historyRetentionDays)
            for r in rows { store.upsert(r) }
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

private extension SessionStore.SessionRow {
    var cellView: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(cellStatusColor.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: cellStatusSystemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(cellStatusColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(cellAgentDisplayName).font(.subheadline.bold())
                Text("\(cwdBasename) · \(totalToolCalls) tools · \(durationString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var cellAgentDisplayName: String {
        switch agent {
        case "claude":      return "Claude Code"
        case "cursor":      return "Cursor"
        case "vscode":      return "VS Code"
        case "copilot_cli": return "Copilot CLI"
        case "windsurf":    return "Windsurf"
        case "codex_cli":   return "Codex CLI"
        default:            return agent.capitalized
        }
    }

    var cellStatusSystemImage: String {
        switch status {
        case .completed:       return "checkmark.circle.fill"
        case .failed:          return "xmark.circle.fill"
        case .running:         return "circle.fill"
        case .waitingApproval: return "exclamationmark.circle.fill"
        }
    }

    var cellStatusColor: Color {
        switch status {
        case .completed:       return .gray
        case .failed:          return .red
        case .running:         return .green
        case .waitingApproval: return .orange
        }
    }

    var durationString: String {
        let end = endedAt ?? lastEventAt
        let s = Int(end.timeIntervalSince(startedAt))
        let mins = s / 60
        let secs = s % 60
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }
}
