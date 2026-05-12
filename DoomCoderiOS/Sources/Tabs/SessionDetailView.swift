import SwiftUI

struct SessionDetailView: View {
    let sessionKey: String
    @State private var aggregate: CKSessionAggregate?
    @State private var events: [CKAgentEvent] = []
    @State private var loading = true
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let agg = aggregate { header(agg) }
                stats
                timeline
            }
            .padding()
        }
        .background(LinearGradient(colors: [Color(white: 0.06), Color(white: 0.02)],
                                   startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .navigationTitle(aggregate?.cwdBasename ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { copyJSON() } label: { Image(systemName: "doc.on.doc") }
            }
        }
        .task { await load() }
    }

    private func header(_ agg: CKSessionAggregate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(statusEmoji(agg.status)) \(agg.agent.capitalized)")
                .font(.title2.bold())
            Text(agg.cwdBasename).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var stats: some View {
        if let agg = aggregate {
            VStack(alignment: .leading, spacing: 6) {
                statRow("Model", agg.model ?? "—")
                statRow("Tools", "\(agg.totalToolCalls)")
                statRow("Files edited", "\(agg.totalFilesEdited)")
                statRow("Errors", "\(agg.totalErrors)")
                statRow("Started", agg.startedAt.formatted(date: .abbreviated, time: .standard))
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func statRow(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).font(.callout) }
    }

    @ViewBuilder private var timeline: some View {
        if loading {
            ProgressView().padding()
        } else if let err = loadError {
            Text("Error: \(err)").foregroundStyle(.red)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Timeline").font(.headline)
                ForEach(events.indices, id: \.self) { idx in
                    let e = events[idx]
                    HStack(alignment: .top, spacing: 8) {
                        Text(e.occurredAt.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(phaseGlyph(e.hookPhase))
                        Text(e.hookPhase).font(.caption.bold())
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func phaseGlyph(_ phase: String) -> String {
        switch phase.lowercased() {
        case "sessionstart": return "▶"
        case "sessionstop", "sessionend": return "■"
        case "userprompt": return "💬"
        case "pretool", "pretooluse": return "🛠"
        case "posttool", "posttooluse": return "✓"
        default: return "•"
        }
    }

    private func statusEmoji(_ s: CKSessionAggregate.Status) -> String {
        switch s {
        case .running: return "🟢"
        case .waitingApproval: return "🟠"
        case .completed: return "✅"
        case .failed: return "🔴"
        }
    }

    private func load() async {
        loading = true
        do {
            aggregate = try await CloudKitClient.shared.fetchAggregate(sessionKey: sessionKey)
            events = try await CloudKitClient.shared.fetchEvents(sessionKey: sessionKey)
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func copyJSON() {
        guard let agg = aggregate else { return }
        let dict: [String: Any] = [
            "sessionKey": agg.sessionKey,
            "agent": agg.agent,
            "cwdBasename": agg.cwdBasename,
            "status": agg.status.rawValue,
            "totalToolCalls": agg.totalToolCalls,
            "totalFilesEdited": agg.totalFilesEdited,
            "events": events.map { ["phase": $0.hookPhase, "at": $0.occurredAt.timeIntervalSince1970] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            UIPasteboard.general.string = str
        }
    }
}

#if canImport(UIKit)
import UIKit
#endif
