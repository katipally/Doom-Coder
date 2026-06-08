import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - ActivityView
//
// The "Activity" tab (formerly Logs). Designed as a single full-width column so
// it sits cleanly inside the Configure window's detail pane — no second sidebar.
//
// HIG structure (macOS 26):
//   • A scrollable tab bar of agent chips (icon + label + live dot + count) for
//     filtering by agent. Derived from TrackedAgent.allCases, so new agents
//     appear automatically.
//   • A filter row: a segmented control (All | Notifications) + a sort pop-up.
//   • A full-width session list, grouped by Today / Yesterday / Earlier.
//   • Tapping a session opens its full hook timeline in a sheet (Timeline | Raw).
//   • A toolbar search field + an overflow menu (export / retention / clear /
//     raw events).
//
// Robustness: sessions are reconstructed from the raw events table
// (`ActivitySessionBuilder`), so runs that never ended cleanly still appear,
// badged `.incomplete`. Notifications merge inline (🔔) with the scope toggle.

struct ActivityView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case sessions = "Sessions"           // grouped session list
        case raw = "Raw"                     // every raw event (flat firehose)
        case notifications = "Notifications"  // raw events that triggered a notification
        var id: String { rawValue }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case newest = "Newest first"
        case oldest = "Oldest first"
        var id: String { rawValue }
    }

    enum AgentSel: Hashable {
        case all
        case agent(TrackedAgent)
    }

    @State private var agentSel: AgentSel = .all
    @State private var filter: Filter = .sessions
    @State private var sortOrder: SortOrder = .newest
    @State private var search: String = ""
    @State private var sessions: [ActivitySession] = []
    @State private var rawRows: [EventStore.Row] = []
    @State private var allNotifs: [EventStore.NotificationRow] = []
    @State private var totalEventCount: Int = 0
    @State private var retentionDays: Int = EventStore.retentionDays
    @State private var selectedSession: ActivitySession? = nil
    @State private var showClearConfirm = false

    // Live state — @Observable, drives the pulsing per-agent indicators.
    @State private var tracking = AgentTrackingManager.shared
    @Namespace private var chipNamespace

    var body: some View {
        VStack(spacing: 0) {
            agentTabBar
            Divider()
            filterRow
            Divider()
            content
        }
        .searchable(text: $search, placement: .toolbar, prompt: searchPrompt)
        .toolbar { utilityMenu }
        .sheet(item: $selectedSession) { s in
            SessionSheet(session: s)
        }
        .confirmationDialog("Clear all activity?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) {
                EventStore.shared.clearAll()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all recorded events, notifications, and session history for every agent.")
        }
        .onAppear { reload() }
        .onChange(of: agentSel) { _, _ in refreshRaw() }
        .onReceive(NotificationCenter.default.publisher(for: .doomcoderNewEvent)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .doomcoderProcessStateChanged)) { _ in reload() }
    }

    // MARK: - Agent tab bar

    private var agentTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                agentChip(
                    selection: .all,
                    icon: AnyView(Image(systemName: "square.stack.3d.up.fill").font(.callout).foregroundStyle(.tint)),
                    label: "All",
                    live: anyAgentLive,
                    count: countFor(.all)
                )
                ForEach(TrackedAgent.allCases, id: \.self) { agent in
                    agentChip(
                        selection: .agent(agent),
                        icon: AnyView(AgentIconView(agent: agent, size: 16)),
                        label: agent.displayName,
                        live: isLiveAgent(agent),
                        count: countFor(.agent(agent))
                    )
                }
            }
            .padding(.horizontal, 10)
            .animation(DCAnim.snap, value: agentSel)
        }
        .frame(height: 44)
    }

    private func agentChip(selection: AgentSel, icon: AnyView, label: String, live: Bool, count: Int) -> some View {
        let isSelected = agentSel == selection
        let isEmpty = count == 0 && !live
        return Button {
            withAnimation(DCAnim.snap) { agentSel = selection }
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    icon
                    Text(label)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                    if live { liveDot }
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(
                                (isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.15)),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .contentTransition(.numericText())
                    }
                }
                .foregroundStyle(isSelected ? Color.primary : (isEmpty ? Color.secondary.opacity(0.55) : .secondary))
                // Animated selection underline.
                ZStack {
                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(height: 2.5)
                            .matchedGeometryEffect(id: "agentUnderline", in: chipNamespace)
                    } else {
                        Color.clear.frame(height: 2.5)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private var liveDot: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(.green)
            .symbolEffect(.pulse, options: .repeating, isActive: true)
            .accessibilityLabel("Live")
    }

    // MARK: - Filter row

    private var filterRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Picker("View", selection: $filter) {
                    ForEach(Filter.allCases) { f in Text(f.rawValue).tag(f) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { o in Text(o.rawValue).tag(o) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Text(filterHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// One-line explanation of the currently selected Activity view.
    private var filterHint: String {
        switch filter {
        case .sessions:      return "Each agent run, grouped from start to finish."
        case .notifications: return "Only the events that triggered an alert you received."
        case .raw:           return "Every raw hook event, newest first — the full firehose."
        }
    }

    // MARK: - Content (switches on the filter)

    @ViewBuilder
    private var content: some View {
        switch filter {
        case .sessions:      sessionList
        case .notifications: rawEventsView(onlyNotified: true)
        case .raw:           rawEventsView(onlyNotified: false)
        }
    }

    // MARK: - Session list

    @ViewBuilder
    private var sessionList: some View {
        let rows = listRows
        if rows.isEmpty {
            ContentUnavailableView(
                "No sessions",
                systemImage: "tray",
                description: Text("Agent sessions appear here as hooks fire.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        switch row {
                        case .dateHeader(let title):
                            Text(title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .tracking(0.6)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 6)
                                .padding(.horizontal, 4)
                        case .session(let s):
                            Button {
                                selectedSession = s
                            } label: {
                                ActivitySessionRow(session: s, showAgent: agentSel == .all)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(14)
                .animation(DCAnim.snap, value: agentSel)
            }
        }
    }

    // MARK: - Raw events list (Notifications + Raw filters)

    @ViewBuilder
    private func rawEventsView(onlyNotified: Bool) -> some View {
        let rows = rawEvents(onlyNotified: onlyNotified)
        if rows.isEmpty {
            ContentUnavailableView(
                onlyNotified ? "No notifications" : "No events",
                systemImage: onlyNotified ? "bell.slash" : "tray",
                description: Text(onlyNotified
                    ? "Raw events that triggered a notification appear here."
                    : "Every raw hook event appears here, newest first.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(rows) { row in
                        RawEventRow(row: row, showAgent: agentSel == .all)
                    }
                }
                .padding(.vertical, 4)
                .animation(DCAnim.snap, value: agentSel)
            }
        }
    }

    // MARK: - Toolbar overflow menu

    private var utilityMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section("Export") {
                    Button { exportJSON() } label: { Label("Export JSON…", systemImage: "arrow.down.doc") }
                    Button { exportCSV() } label: { Label("Export CSV…", systemImage: "tablecells") }
                }
                Section("Keep events for") {
                    Picker("Retention", selection: Binding(
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
                }
                Section {
                    Button(role: .destructive) { showClearConfirm = true } label: {
                        Label("Clear All…", systemImage: "trash")
                    }
                }
            } label: {
                Label("Activity options", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .help("Export, retention, and clear")
        }
    }

    private var searchPrompt: String {
        switch filter {
        case .sessions:      return "Search sessions"
        case .notifications: return "Search notifications"
        case .raw:           return "Search events"
        }
    }

    // MARK: - Data

    private func reload() {
        sessions = ActivitySessionBuilder.build(agentFilter: nil, limit: 300)
        allNotifs = EventStore.shared.recentNotifications(limit: 1000)
        totalEventCount = EventStore.shared.count()
        refreshRaw()
    }

    /// Loads raw events for the *currently selected* agent. Querying per-agent
    /// (rather than filtering one shared global buffer) means a chatty agent
    /// can't crowd a quieter one out of its own Raw/Notifications view — every
    /// agent gets its own full recent set.
    private func refreshRaw() {
        switch agentSel {
        case .all:            rawRows = EventStore.shared.recent(limit: 1000)
        case .agent(let a):   rawRows = EventStore.shared.recent(agent: a.rawValue, limit: 1000)
        }
    }

    /// Sessions after agent + search filters, sorted (live first).
    private var visibleSessions: [ActivitySession] {
        let base = sessions.filter { matchesAgent($0) && matchesSearch($0) }
        return base.sorted { a, b in
            if a.isLive != b.isLive { return a.isLive && !b.isLive }
            return sortOrder == .newest ? a.endedAt > b.endedAt : a.endedAt < b.endedAt
        }
    }

    /// Raw events for the Raw / Notifications filters. `rawRows` is already
    /// scoped to the selected agent (see `refreshRaw`), so this only layers on
    /// the notification filter, search, and sort.
    private func rawEvents(onlyNotified: Bool) -> [EventStore.Row] {
        var rows = rawRows
        if onlyNotified {
            let notifs: [EventStore.NotificationRow]
            switch agentSel {
            case .all:          notifs = allNotifs
            case .agent(let a): notifs = allNotifs.filter { $0.agent == a.rawValue }
            }
            let ids = Self.notifiedIDs(among: rows, notifications: notifs)
            rows = rows.filter { ids.contains($0.id) }
        }
        if !search.isEmpty {
            let q = search.lowercased()
            rows = rows.filter {
                $0.event.lowercased().contains(q)
                || ($0.tool?.lowercased().contains(q) ?? false)
                || $0.agent.lowercased().contains(q)
            }
        }
        // rawRows is newest-first (id DESC); reverse for oldest-first.
        return sortOrder == .newest ? rows : rows.reversed()
    }

    /// For each notification, find the raw event that triggered it (no FK
    /// exists), matching on session + event name + nearest timestamp.
    private static func notifiedIDs(among rows: [EventStore.Row],
                                    notifications: [EventStore.NotificationRow]) -> Set<Int64> {
        guard !notifications.isEmpty else { return [] }
        var ids = Set<Int64>()
        for n in notifications {
            let sameSession = rows.filter { $0.sessionKey == n.sessionKey }
            let pool = sameSession.isEmpty ? rows : sameSession
            let named = pool.filter { $0.event == n.event }
            let candidates = named.isEmpty ? pool : named
            if let best = candidates.min(by: { abs($0.ts - n.ts) < abs($1.ts - n.ts) }) {
                ids.insert(best.id)
            }
        }
        return ids
    }

    private func matchesAgent(_ s: ActivitySession) -> Bool {
        switch agentSel {
        case .all: return true
        case .agent(let a): return s.agent == a
        }
    }

    private func matchesSearch(_ s: ActivitySession) -> Bool {
        guard !search.isEmpty else { return true }
        let q = search.lowercased()
        return s.displayName.lowercased().contains(q) || s.sessionKey.lowercased().contains(q)
    }

    private func countFor(_ sel: AgentSel) -> Int {
        sessions.filter { s in
            guard matchesSearch(s) else { return false }
            switch sel {
            case .all: return true
            case .agent(let a): return s.agent == a
            }
        }.count
    }

    private func isLiveAgent(_ agent: TrackedAgent) -> Bool {
        switch tracking.effectiveState(for: agent) {
        case .running, .waitingInput, .waitingApproval: return true
        default: return false
        }
    }

    private var anyAgentLive: Bool {
        TrackedAgent.allCases.contains { isLiveAgent($0) }
    }

    // MARK: - List rows with date dividers

    private enum ListRow: Identifiable {
        case dateHeader(String)
        case session(ActivitySession)
        var id: String {
            switch self {
            case .dateHeader(let s): return "h-\(s)"
            case .session(let x): return x.sessionKey
            }
        }
    }

    private var listRows: [ListRow] {
        var out: [ListRow] = []
        var lastBucket: String? = nil
        for s in visibleSessions {
            let bucket = ActivityFormat.dateBucket(s.endedAt)
            if bucket != lastBucket {
                out.append(.dateHeader(bucket))
                lastBucket = bucket
            }
            out.append(.session(s))
        }
        return out
    }

    // MARK: - Export

    private func exportJSON() {
        let key: String? = { if case .agent(let a) = agentSel { return a.rawValue } else { return nil } }()
        guard let data = EventStore.shared.exportJSON(agent: key) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "doomcoder-activity.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }

    private func exportCSV() {
        let key: String? = { if case .agent(let a) = agentSel { return a.rawValue } else { return nil } }()
        let csv = EventStore.shared.exportCSV(agent: key)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "doomcoder-activity.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url { try? csv.write(to: url, atomically: true, encoding: .utf8) }
    }
}

// MARK: - Session row (list)

private struct ActivitySessionRow: View {
    let session: ActivitySession
    let showAgent: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.outcome.symbol)
                .font(.body)
                .foregroundStyle(session.outcome.color)
                .frame(width: 20)
                .symbolEffect(.pulse, options: .repeating, isActive: session.isLive)

            if showAgent { agentBadge }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if showAgent {
                        Text(session.displayName).font(.callout.weight(.semibold))
                    } else {
                        Text(session.isLive ? "Running…" : session.outcome.label)
                            .font(.callout.weight(.semibold))
                    }
                    if showAgent { outcomePill }
                    if session.hasNotifications {
                        Image(systemName: "bell.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .doomGlassCard(cornerRadius: 12)
    }

    private var agentBadge: some View {
        Group {
            if let agent = session.agent {
                AgentIconView(agent: agent, size: 24)
            } else {
                Circle().fill(TrackedAgent.brandColor(forKey: session.agentKey)).frame(width: 12, height: 12)
            }
        }
    }

    private var outcomePill: some View {
        let o = session.outcome
        return HStack(spacing: 3) {
            Image(systemName: o.symbol)
                .font(.system(size: 9))
                .symbolEffect(.pulse, options: .repeating, isActive: session.isLive)
            Text(session.isLive ? "Running" : o.label).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(o.color.opacity(0.14), in: Capsule())
        .foregroundStyle(o.color)
    }

    private var subtitle: String {
        var parts: [String] = []
        if session.isLive { parts.append("started \(ActivityFormat.relative(session.startedAt))") }
        else { parts.append(ActivityFormat.relative(session.endedAt)) }
        parts.append(ActivityFormat.duration(session.duration))
        if session.toolCount > 0 { parts.append("\(session.toolCount) tools") }
        else { parts.append("\(session.eventCount) events") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Session detail sheet

private struct SessionSheet: View {
    let session: ActivitySession
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case timeline = "Timeline"
        case raw = "Raw"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .timeline
    @State private var events: [EventStore.Row] = []
    @State private var notifiedEventIDs: Set<Int64> = []
    @State private var expandedID: Int64? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if mode == .raw { rawTimeline } else { structuredTimeline }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 460)
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .doomcoderNewEvent)) { _ in
            if session.isLive { load() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                agentBadge
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(session.displayName).font(.headline)
                        outcomePill
                    }
                    Text(timeRange).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Done")
            }

            HStack {
                Text(summaryStat).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }

            if session.outcome == .incomplete { incompleteNote }
        }
        .padding(16)
    }

    private var agentBadge: some View {
        Group {
            if let agent = session.agent {
                AgentIconView(agent: agent, size: 30)
            } else {
                Circle().fill(TrackedAgent.brandColor(forKey: session.agentKey)).frame(width: 14, height: 14)
            }
        }
    }

    private var outcomePill: some View {
        let o = session.outcome
        return HStack(spacing: 4) {
            Image(systemName: o.symbol)
                .font(.caption2)
                .symbolEffect(.pulse, options: .repeating, isActive: session.isLive)
            Text(session.isLive ? "Running" : o.label).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(o.color.opacity(0.14), in: Capsule())
        .foregroundStyle(o.color)
    }

    private var incompleteNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").font(.caption).foregroundStyle(.orange)
            Text("No session-end was received — this run was reconstructed from its events. It may have been interrupted (the agent or app quit, slept, or crashed).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Timelines

    @ViewBuilder
    private var structuredTimeline: some View {
        if events.isEmpty {
            ContentUnavailableView("No events", systemImage: "tray")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(events) { ev in
                        timelineRow(ev)
                        Divider().opacity(0.4)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func timelineRow(_ ev: EventStore.Row) -> some View {
        let isExpanded = expandedID == ev.id
        let notified = notifiedEventIDs.contains(ev.id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard ev.payload != nil else { return }
                withAnimation(DCAnim.micro) { expandedID = isExpanded ? nil : ev.id }
            } label: {
                HStack(spacing: 8) {
                    Text(ActivityFormat.time(ev.ts))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 60, alignment: .leading)
                    phaseIcon(ev.state)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ev.event).font(.caption.weight(.medium)).lineLimit(1)
                        if let tool = ev.tool {
                            Text(tool).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if notified {
                        Image(systemName: "bell.fill").font(.system(size: 9)).foregroundStyle(.orange)
                            .help("Sent a notification")
                    }
                    if ev.payload != nil {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, let payload = ev.payload {
                PayloadRendererView(json: payload)
            }
        }
        .background(isExpanded ? Color.accentColor.opacity(0.04) : Color.clear)
    }

    @ViewBuilder
    private var rawTimeline: some View {
        if events.isEmpty {
            ContentUnavailableView("No events", systemImage: "tray")
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(events) { ev in RawEventRow(row: ev, showAgent: false) }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Data

    private func load() {
        let evs = EventStore.shared.events(forSessionKey: session.sessionKey)
        events = evs
        notifiedEventIDs = Self.computeNotifiedIDs(sessionKey: session.sessionKey, events: evs)
    }

    /// Maps each notification in the session to its nearest matching event (no FK
    /// exists), matching on event name + closest timestamp.
    private static func computeNotifiedIDs(sessionKey: String, events: [EventStore.Row]) -> Set<Int64> {
        let notifs = EventStore.shared.recentNotifications(limit: 1000).filter { $0.sessionKey == sessionKey }
        guard !notifs.isEmpty else { return [] }
        var ids = Set<Int64>()
        for n in notifs {
            let candidates = events.filter { $0.event == n.event }
            let pool = candidates.isEmpty ? events : candidates
            if let best = pool.min(by: { abs($0.ts - n.ts) < abs($1.ts - n.ts) }) {
                ids.insert(best.id)
            }
        }
        return ids
    }

    private var timeRange: String {
        "\(ActivityFormat.time(session.startedAt)) – \(ActivityFormat.time(session.endedAt)) · \(ActivityFormat.duration(session.duration))"
    }

    private var summaryStat: String {
        var parts: [String] = ["\(session.eventCount) events"]
        if session.toolCount > 0 { parts.append("\(session.toolCount) tools") }
        if session.permissionCount > 0 { parts.append("\(session.permissionCount) approvals") }
        if session.subagentCount > 0 { parts.append("\(session.subagentCount) sub-agents") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Raw event row (firehose)

private struct RawEventRow: View {
    let row: EventStore.Row
    let showAgent: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard row.payload != nil else { return }
                withAnimation(DCAnim.micro) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if showAgent {
                        if let agent = TrackedAgent(rawValue: row.agent) {
                            AgentIconView(agent: agent, size: 16)
                        } else {
                            Circle().fill(TrackedAgent.brandColor(forKey: row.agent)).frame(width: 8, height: 8)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(row.event).font(.caption.weight(.medium))
                            if let tool = row.tool {
                                Text("· \(tool)").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Text(ActivityFormat.time(row.ts))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if row.payload != nil {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let payload = row.payload {
                PayloadRendererView(json: payload)
            }
        }
        .background(expanded ? Color.accentColor.opacity(0.04) : Color.clear)
    }
}

// MARK: - Phase icon (shared)

@ViewBuilder
private func phaseIcon(_ state: String?) -> some View {
    let (sym, col): (String, Color) = {
        switch state {
        case "running", "toolStart":          return ("play.fill", .green)
        case "toolEnd":                       return ("checkmark.circle", .secondary)
        case "toolError", "error":            return ("exclamationmark.triangle", .red)
        case "permissionNeeded":              return ("hand.raised.fill", .orange)
        case "sessionStart":                  return ("circle", .accentColor)
        case "sessionEnd", "completed":       return ("checkmark.circle.fill", .green)
        case "agentResponse", "waitingInput": return ("ellipsis.circle", .yellow)
        case "subagentStart", "subagentEnd":  return ("arrow.triangle.branch", .purple)
        default:                              return ("circle.dotted", .secondary)
        }
    }()
    Image(systemName: sym)
        .font(.caption2)
        .foregroundStyle(col)
        .frame(width: 14)
        .accessibilityHidden(true)
}

// MARK: - Formatting (shared)

enum ActivityFormat {
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    static func time(_ ts: TimeInterval) -> String { timeFmt.string(from: Date(timeIntervalSince1970: ts)) }
    static func time(_ date: Date) -> String { timeFmt.string(from: date) }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86_400))d ago"
    }

    static func dateBucket(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return "Earlier"
    }
}
