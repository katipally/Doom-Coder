import SwiftUI

struct HistoryTab: View {
    @EnvironmentObject var store: SessionStore
    @State private var search: String = ""
    @State private var filter: AgentFilter = .all

    enum AgentFilter: String, CaseIterable, Identifiable {
        case all, claude, codex, cursor, copilot, windsurf
        var id: String { rawValue }
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
                            Button(f.rawValue.capitalized) { filter = f }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
            }
            .task { await refresh() }
        }
    }

    @ViewBuilder private var list: some View {
        if filteredRows.isEmpty {
            VStack(spacing: 10) {
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
            let matchesAgent = (filter == .all) || row.agent.lowercased() == filter.rawValue
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
        HStack {
            Text(statusEmoji)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(agent.capitalized) · \(cwdBasename)").font(.subheadline.bold())
                Text("\(totalToolCalls) tools · \(durationString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    var statusEmoji: String {
        switch status {
        case .completed: return "✅"
        case .failed: return "❌"
        case .running: return "🟢"
        case .waitingApproval: return "🟠"
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
