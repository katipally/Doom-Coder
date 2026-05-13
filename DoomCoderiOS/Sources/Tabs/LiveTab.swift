import SwiftUI
import UIKit

// Agent brand helpers delegate to AgentBrand — single source of truth in AgentBrandIcon.swift

private func agentSFSymbol(_ agent: String) -> String { AgentBrand(rawAgent: agent).sfSymbolName }
private func agentDisplayName(_ agent: String) -> String { AgentBrand(rawAgent: agent).fullDisplayName }
private func agentBrandColor(_ agent: String) -> Color { AgentBrand(rawAgent: agent).primaryColor }

struct LiveTab: View {
    @EnvironmentObject var store: SessionStore
    @State private var refreshing = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(white: 0.06), Color(white: 0.02)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                content
            }
            .navigationTitle("Live")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task { await refresh() }
        }
    }

    @ViewBuilder private var content: some View {
        if store.liveSessions.isEmpty {
            empty
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(store.liveSessions) { row in
                        NavigationLink(value: row.id) { SessionCard(row: row) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .refreshable { await refresh() }
            .navigationDestination(for: String.self) { key in
                SessionDetailView(sessionKey: key)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No active agents").font(.title3.bold())
            Text("Open a session on your Mac and it will appear here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button {
                Task { await DevicePresenceUpdater.shared.heartbeat(); await refresh() }
            } label: { Text("Verify connection").padding(.horizontal, 16) }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
    }

    private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        do {
            let active = try await CloudKitClient.shared.fetchActiveSessions()
            for a in active { store.upsert(a) }
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

struct SessionCard: View {
    let row: SessionStore.SessionRow

    private var brandColor: Color { agentBrandColor(row.agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if row.status == .waitingApproval {
                Divider()
                    .padding(.horizontal, 14)
                    .overlay(brandColor.opacity(0.3))
                approvalSection
            } else if row.status == .running {
                runningSection
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(brandColor.opacity(row.status == .waitingApproval ? 0.5 : 0.12))
        )
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            AgentBrandIcon(agent: row.agent, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(agentDisplayName(row.agent))
                    .font(.headline)
                Text(row.cwdBasename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                statusPill
                if row.status == .running {
                    ElapsedText(since: row.startedAt)
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
    }

    private var statusPill: some View {
        HStack(spacing: 3) {
            Image(systemName: statusSystemImage)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(statusColor)
            Text(statusLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(statusColor.opacity(0.15), in: Capsule())
    }

    private var approvalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tool = row.currentTool {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("\(tool) needs approval")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let rid = row.pendingRequestId {
                HStack(spacing: 8) {
                    Button {
                        Task {
                            let uuid = DevicePresenceUpdater.shared.deviceUUID()
                            try? await CloudKitClient.shared.writeApprovalResponse(
                                requestId: rid, decision: "approve", deviceUUID: uuid)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.green)

                    Button {
                        Task {
                            let uuid = DevicePresenceUpdater.shared.deviceUUID()
                            try? await CloudKitClient.shared.writeApprovalResponse(
                                requestId: rid, decision: "deny", deviceUUID: uuid)
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        }
                    } label: {
                        Label("Deny", systemImage: "xmark")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.red)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            } else {
                Text("Loading approval details…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 8)
    }

    private var runningSection: some View {
        HStack(spacing: 6) {
            if let tool = row.currentTool {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(tool)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ActivityDots()
            }
            Spacer()
            Text("\(row.totalToolCalls) tools")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var statusSystemImage: String {
        switch row.status {
        case .running:         return "circle.fill"
        case .waitingApproval: return "exclamationmark.circle.fill"
        case .completed:       return "checkmark.circle.fill"
        case .failed:          return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .running:         return .green
        case .waitingApproval: return .orange
        case .completed:       return .gray
        case .failed:          return .red
        }
    }

    private var statusLabel: String {
        switch row.status {
        case .running:         return "Running"
        case .waitingApproval: return "Waiting"
        case .completed:       return "Done"
        case .failed:          return "Failed"
        }
    }
}

// Six-dot animated activity indicator with a staggered 1.2s fade-in-sequence cycle.
private struct ActivityDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.2) / 1.2
            HStack(spacing: 3) {
                ForEach(0..<6, id: \.self) { i in
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                        .opacity(dotOpacity(index: i, phase: phase))
                }
            }
        }
    }

    private func dotOpacity(index: Int, phase: Double) -> Double {
        let offset = Double(index) / 6.0
        var p = (phase + offset).truncatingRemainder(dividingBy: 1.0)
        if p < 0 { p += 1.0 }
        return 0.15 + 0.75 * max(0.0, sin(p * .pi))
    }
}

// Elapsed timer that refreshes once per second using a periodic TimelineView.
private struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { _ in
            Text(formatted)
        }
    }

    private var formatted: String {
        let elapsed = max(0, Int(Date().timeIntervalSince(since)))
        let mins = elapsed / 60
        let secs = elapsed % 60
        return "⏱ \(mins):\(String(format: "%02d", secs))"
    }
}
