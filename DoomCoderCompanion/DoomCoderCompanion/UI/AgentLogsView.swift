// AgentLogsView.swift — DoomCoder Companion
// Per-agent view: capability card at top, notification tray below (capped height, inner scroll).

import SwiftUI
import DoomCoderCore

struct AgentLogsView: View {
    let agent: TrackedAgent

    @State private var logs: [NotificationLogRecord] = []
    @State private var isLoading = true
    @State private var showClearConfirm = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 16) {
                capabilityCard
                notificationTray
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(agent.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadLogs() }
        .refreshable {
            await loadLogs()
            await CompanionSyncEngine.shared.fetchChanges()
        }
        .alert("Clear notifications for \(agent.displayName)?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) { clearLogs() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all notification history for this agent on this device.")
        }
    }

    // MARK: - Capability card

    private var capabilityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What this agent delivers")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            let caps = AgentCapabilityCatalog.capabilities(for: agent)
            if caps.isEmpty {
                Text("No capability info available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(caps) { cap in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: cap.symbolName)
                            .foregroundStyle(.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cap.title).font(.callout.weight(.medium))
                            Text(cap.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Notification tray

    private var notificationTray: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Notification Activity")
                    .font(.subheadline.weight(.semibold))
                Text("(\(logs.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if !logs.isEmpty {
                    Button("Clear All") { showClearConfirm = true }
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Content
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 24)
                    Spacer()
                }
            } else if logs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No notifications yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                let trayHeight = min(CGFloat(logs.count), 4) * 100
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(logs, id: \.notifId) { log in
                            LogRow(log: log)
                                .padding(.horizontal, 16)
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
                .frame(height: trayHeight)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions

    private func loadLogs() async {
        isLoading = true
        logs = await NotificationLogStore.shared.fetchLogs(forAgent: agent)
        isLoading = false
    }

    private func clearLogs() {
        NotificationLogStore.shared.clear(forAgent: agent)
        logs = []
    }
}

// MARK: - LogRow (unchanged)

struct LogRow: View {
    let log: NotificationLogRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(formatTime(log.ts))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                PhasePill(phase: log.phase)
            }

            Text(log.title)
                .font(.body.weight(.medium))

            if !log.body.isEmpty {
                Text(log.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let tool = log.lastTool, !tool.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption2)
                    Text(tool)
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 10)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            formatter.timeStyle = .short
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            formatter.timeStyle = .short
            return "Yesterday " + formatter.string(from: date)
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
    }
}

// MARK: - PhasePill (unchanged)

struct PhasePill: View {
    let phase: String

    var body: some View {
        Text(displayText)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .clipShape(Capsule())
    }

    private var normalizedPhase: NormalizedEventPhase? {
        NormalizedEventPhase(rawValue: phase)
    }

    private var displayText: String {
        guard let p = normalizedPhase else { return phase }
        switch p {
        case .sessionStart: return "Start"
        case .sessionEnd: return "End"
        case .userPrompt: return "Prompt"
        case .toolStart: return "Tool"
        case .toolEnd: return "Done"
        case .toolError: return "Error"
        case .permissionNeeded: return "Permission"
        case .agentResponse: return "Response"
        case .subagentStart: return "Sub-agent"
        case .subagentEnd: return "Sub-end"
        case .error: return "Error"
        case .other: return "Other"
        }
    }

    private var backgroundColor: Color {
        guard let p = normalizedPhase else { return .gray.opacity(0.2) }
        switch p.iOSInterruptionLevel {
        case .timeSensitive: return .red.opacity(0.2)
        case .active: return .blue.opacity(0.2)
        case .passive: return .gray.opacity(0.2)
        case .critical: return .red.opacity(0.3)
        }
    }

    private var foregroundColor: Color {
        guard let p = normalizedPhase else { return .secondary }
        switch p.iOSInterruptionLevel {
        case .timeSensitive: return .red
        case .active: return .blue
        case .passive: return .secondary
        case .critical: return .red
        }
    }
}
