import Foundation
import CloudKit
import Combine

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published var liveSessions: [SessionRow] = []
    @Published var history: [SessionRow] = []
    @Published var focusedSessionKey: String?
    @Published var lastError: String?

    struct SessionRow: Identifiable, Equatable {
        let id: String
        var agent: String
        var agentVariant: String?
        var macHostname: String
        var cwdBasename: String
        var startedAt: Date
        var lastEventAt: Date
        var endedAt: Date?
        var status: CKSessionAggregate.Status
        var currentTool: String?
        var totalToolCalls: Int
        var totalFilesEdited: Int
        var totalErrors: Int
        var model: String?
        var promptPreview: String?
        var pendingRequestId: String?
    }

    private init() {
        // Clean up stale "live" sessions every 5 minutes.
        // Sessions stuck in running/waitingApproval with no event for 30+ min
        // are considered orphaned (e.g. Mac app crashed without sending sessionStop).
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cleanupStaleSessions() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cleanupStaleSessions() {
        let threshold = Date().addingTimeInterval(-1800) // 30 min
        let stale = liveSessions.filter { row in
            (row.status == .running || row.status == .waitingApproval) &&
            row.lastEventAt < threshold
        }
        for row in stale {
            var tombstone = row
            tombstone.status = .completed  // move to history rather than delete
            tombstone.endedAt = row.lastEventAt
            liveSessions.removeAll { $0.id == row.id }
            if !history.contains(where: { $0.id == row.id }) {
                history.insert(tombstone, at: 0)
            }
        }
    }

    func upsert(_ agg: CKSessionAggregate) {
        let row = SessionRow(
            id: agg.sessionKey,
            agent: agg.agent,
            agentVariant: agg.agentVariant,
            macHostname: agg.macHostname,
            cwdBasename: agg.cwdBasename,
            startedAt: agg.startedAt,
            lastEventAt: agg.lastEventAt,
            endedAt: agg.endedAt,
            status: agg.status,
            currentTool: agg.currentTool,
            totalToolCalls: agg.totalToolCalls,
            totalFilesEdited: agg.totalFilesEdited,
            totalErrors: agg.totalErrors,
            model: agg.model,
            promptPreview: agg.promptPreview,
            pendingRequestId: agg.pendingRequestId
        )
        if agg.status == .running || agg.status == .waitingApproval {
            if let idx = liveSessions.firstIndex(where: { $0.id == row.id }) {
                liveSessions[idx] = row
            } else {
                liveSessions.append(row)
            }
            liveSessions.sort { $0.lastEventAt > $1.lastEventAt }
        } else {
            liveSessions.removeAll { $0.id == row.id }
            if let idx = history.firstIndex(where: { $0.id == row.id }) {
                history[idx] = row
            } else {
                history.insert(row, at: 0)
            }
        }
    }

    func setHistory(_ rows: [SessionRow]) {
        self.history = rows
    }
}
