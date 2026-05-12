import SwiftUI

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
            Text("🌙").font(.system(size: 56))
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
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusGlyph
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(row.agent.capitalized) · \(row.cwdBasename)")
                    .font(.headline)
                if row.status == .waitingApproval {
                    Text("⚠ \(row.currentTool ?? "tool") needs approval")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                } else {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(.white.opacity(0.05)))
    }

    private var statusGlyph: some View {
        switch row.status {
        case .running: return Text("🟢")
        case .waitingApproval: return Text("🟠")
        case .completed: return Text("✅")
        case .failed: return Text("🔴")
        }
    }

    private var subtitle: String {
        let elapsed = Int(Date().timeIntervalSince(row.startedAt))
        let mins = elapsed / 60
        let secs = elapsed % 60
        let tool = row.currentTool ?? "—"
        return "\(tool) · \(row.totalToolCalls) tools · \(mins)m \(secs)s"
    }
}
