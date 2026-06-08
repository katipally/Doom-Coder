// NotifyAboutCard.swift — Doom Coder (Mac)
//
// The editable "What you'll be notified about" card shown in
// Configure → Agents. Read mode mirrors the clean summary the user liked;
// tapping Edit flips every supported category into a toggle in place, with
// per-tool and per-approval sub-options expanding underneath. Self-contained:
// owns its own state, loads from / saves to `AgentNotificationStore`, so the
// host window doesn't need any new @State.

import SwiftUI

struct NotifyAboutCard: View {
    let agent: TrackedAgent

    @State private var prefs: AgentNotificationPrefs
    @State private var editing = false

    init(agent: TrackedAgent) {
        self.agent = agent
        _prefs = State(initialValue: AgentNotificationStore.prefs(for: agent))
    }

    private var categories: [NotifCategoryID] { AgentNotificationCatalog.categories(for: agent) }
    private var groupedCategories: [(AgentNotificationCatalog.CategoryGroup, [NotifCategoryID])] {
        AgentNotificationCatalog.groupedCategories(for: agent)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Text(editing
                         ? "Choose what \(agent.displayName) should notify you about."
                         : "Delivered to your Mac (and your iPhone if the companion is installed).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(editing ? "Done" : "Edit") {
                        if editing {
                            AgentNotificationStore.setPrefs(prefs, for: agent)
                            // Re-publish AgentConfig so iOS's read-only
                            // "what you'll be notified about" list re-syncs.
                            NotificationCenter.default.post(name: .trackingStoreChanged, object: nil)
                        }
                        withAnimation(.easeInOut(duration: 0.18)) { editing.toggle() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if editing {
                    // Edit mode: every supported category, bucketed into groups.
                    ForEach(groupedCategories, id: \.0) { group, ids in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                            ForEach(ids, id: \.self) { id in
                                categoryRow(id)
                            }
                        }
                    }
                } else {
                    // Read mode: just the categories currently ON, so the
                    // summary stays clean even as the catalog grows.
                    let on = categories.filter { binding(for: $0).wrappedValue }
                    if on.isEmpty {
                        Text("Nothing selected — tap Edit to choose.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(on, id: \.self) { id in
                            categoryRow(id)
                        }
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("What you'll be notified about", systemImage: "bell.badge")
        }
        .onChange(of: agent) { _, newAgent in
            // Window reuses one card instance across agents in some layouts;
            // reload when the selected agent changes.
            prefs = AgentNotificationStore.prefs(for: newAgent)
            editing = false
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func categoryRow(_ id: NotifCategoryID) -> some View {
        let meta = AgentNotificationCatalog.meta(id)
        let isOn = binding(for: id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: meta.symbol)
                    .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meta.title).font(.callout).bold()
                    Text(summary(for: id, meta: meta))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if editing {
                    Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                } else {
                    Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "minus")
                        .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary.opacity(0.4))
                }
            }
            if editing && isOn.wrappedValue {
                subOptions(for: id)
                    .padding(.leading, 32)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func subOptions(for id: NotifCategoryID) -> some View {
        switch id {
        case .toolCalls:
            VStack(alignment: .leading, spacing: 6) {
                Picker("Notify", selection: $prefs.toolWhen) {
                    Text("When it starts").tag(ToolTrigger.started)
                    Text("When it finishes").tag(ToolTrigger.finished)
                    Text("Both").tag(ToolTrigger.both)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 320)

                Text("Only for these tools:")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(AgentNotificationCatalog.tools(for: agent)) { tool in
                    Toggle(isOn: toolBinding(tool.id)) {
                        HStack(spacing: 4) {
                            Text(tool.label).font(.caption)
                            Image(systemName: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help(tool.tooltip)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help(tool.tooltip)
                }
            }
        case .waitingApproval:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(AgentNotificationCatalog.approvalKinds(for: agent)) { kind in
                    Toggle(isOn: approvalBinding(kind.id)) {
                        HStack(spacing: 4) {
                            Text(kind.title).font(.caption)
                            Image(systemName: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help(kind.tooltip)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help(kind.tooltip)
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Summaries (read mode + edit subtitle)

    private func summary(for id: NotifCategoryID, meta: NotifCategoryMeta) -> String {
        switch id {
        case .toolCalls:
            guard prefs.toolCalls else { return meta.detail }
            let all = AgentNotificationCatalog.tools(for: agent)
            let count = prefs.enabledTools?.count ?? all.count
            let when: String
            switch prefs.toolWhen {
            case .started:  when = "on start"
            case .finished: when = "when finished"
            case .both:     when = "start & finish"
            }
            return "\(count) of \(all.count) tools · \(when)"
        case .waitingApproval:
            guard prefs.waitingApproval else { return meta.detail }
            let all = AgentNotificationCatalog.approvalKinds(for: agent)
            let count = prefs.approvalKinds.intersection(Set(all.map(\.id))).count
            if all.count <= 1 { return meta.detail }
            return "\(count) of \(all.count) kinds"
        default:
            return meta.detail
        }
    }

    // MARK: - Bindings

    private func binding(for id: NotifCategoryID) -> Binding<Bool> {
        switch id {
        case .completed:        return $prefs.completed
        case .failed:           return $prefs.failed
        case .waitingApproval:  return $prefs.waitingApproval
        case .waitingInput:     return $prefs.waitingInput
        case .sessionStart:     return $prefs.sessionStart
        case .toolCalls:        return $prefs.toolCalls
        case .subagentActivity: return $prefs.subagentActivity
        case .fileEdits:         return $prefs.fileEdits
        case .contextCompaction: return $prefs.contextCompaction
        case .agentThinking:     return $prefs.agentThinking
        case .housekeeping:      return $prefs.housekeeping
        case .userPromptSent:    return $prefs.userPromptSent
        }
    }

    private func toolBinding(_ toolID: String) -> Binding<Bool> {
        Binding(
            get: {
                // nil enabledTools == all tools allowed.
                prefs.enabledTools?.contains(toolID) ?? true
            },
            set: { on in
                let allIDs = Set(AgentNotificationCatalog.tools(for: agent).map(\.id))
                var set = prefs.enabledTools ?? allIDs
                if on { set.insert(toolID) } else { set.remove(toolID) }
                prefs.enabledTools = set
            }
        )
    }

    private func approvalBinding(_ kindID: String) -> Binding<Bool> {
        Binding(
            get: { prefs.approvalKinds.contains(kindID) },
            set: { on in
                if on { prefs.approvalKinds.insert(kindID) } else { prefs.approvalKinds.remove(kindID) }
            }
        )
    }
}
