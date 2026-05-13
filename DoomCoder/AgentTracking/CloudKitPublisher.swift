import CloudKit
import Foundation
import Network
import OSLog

@MainActor
final class CloudKitPublisher {
    static let shared = CloudKitPublisher()

    private let logger = Logger(subsystem: "com.doomcoder", category: "cloudkit")
    private let container: CKContainer
    private let db: CKDatabase
    private let debounceInterval: TimeInterval = 0.2
    private var pendingEvents: [CKAgentEvent] = []
    private var pendingAggregates: [String: CKSessionAggregate] = [:]
    private var pendingNotifications: [CKPushNotification] = []
    private var flushTask: Task<Void, Never>?
    private let monitor = NWPathMonitor()
    private var online = true
    private var backoff: TimeInterval = 0

    private init() {
        container = CKContainer(identifier: CloudKitSchema.containerIdentifier)
        db = container.privateCloudDatabase
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = (path.status == .satisfied)
            Task { @MainActor in
                guard let self else { return }
                self.online = ok
                if ok { self.replayOutbox() }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    func publish(event: CKAgentEvent, aggregate: CKSessionAggregate) {
        guard FeatureFlags.cloudKitEnabled else { return }
        let e = Redactor.redact(event: event, minimal: FeatureFlags.minimalMode)
        let a = Redactor.redact(aggregate: aggregate, minimal: FeatureFlags.minimalMode)
        pendingEvents.append(e)
        pendingAggregates[a.sessionKey] = a
        scheduleFlush()
    }

    func publishNotification(_ n: CKPushNotification) {
        guard FeatureFlags.cloudKitEnabled else { return }
        pendingNotifications.append(n)
        scheduleFlush()
    }

    func sendTestEvent() async -> Result<String, Error> {
        let now = Date()
        let key = "diag::\(Int(now.timeIntervalSince1970 * 1000))"
        let event = CKAgentEvent(
            sessionKey: key, agent: "diagnostic", agentVariant: nil,
            macHostname: ProcessInfo.processInfo.hostName, cwdBasename: "DoomCoder",
            cwdHashSuffix: "000000", hookPhase: "diagnostic", occurredAt: now,
            payloadJSON: #"{"diagnostic":true}"#, expiresAt: now.addingTimeInterval(60)
        )
        let record = CKRecord.from(event)
        do {
            _ = try await db.save(record)
            return .success(event.recordName)
        } catch {
            return .failure(error)
        }
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        let delay = debounceInterval + backoff
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() async {
        let events = pendingEvents
        let aggregates = Array(pendingAggregates.values)
        let notifications = pendingNotifications
        pendingEvents.removeAll()
        pendingAggregates.removeAll()
        pendingNotifications.removeAll()
        guard !events.isEmpty || !aggregates.isEmpty || !notifications.isEmpty else { return }

        guard online else {
            spool(events: events, aggregates: aggregates)
            return
        }

        let records = events.map(CKRecord.from(_:)) + aggregates.map(CKRecord.from(_:)) + notifications.map(CKRecord.from(_:))
        do {
            try await modify(records)
            backoff = 0
            logger.debug("flushed \(events.count, privacy: .public) events, \(aggregates.count, privacy: .public) aggregates, \(notifications.count, privacy: .public) push notifications")
        } catch let err as CKError where err.code == .requestRateLimited || err.code == .serviceUnavailable {
            let retry = (err.userInfo[CKErrorRetryAfterKey] as? TimeInterval) ?? 5
            backoff = min(max(retry, backoff * 2 + 1), 300)
            spool(events: events, aggregates: aggregates)
            logger.notice("rate limited, backoff=\(self.backoff, privacy: .public)s")
        } catch {
            spool(events: events, aggregates: aggregates)
            logger.error("flush failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func modify(_ records: [CKRecord]) async throws {
        guard !records.isEmpty else { return }
        let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        op.savePolicy = .changedKeys
        op.qualityOfService = .utility
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            db.add(op)
        }
    }

    // MARK: - Offline outbox (JSON file)

    private struct OutboxFile: Codable {
        var events: [CKAgentEvent]
        var aggregates: [CKSessionAggregate]
    }

    private var outboxURL: URL {
        AgentSupportDir.url.appendingPathComponent("cloudkit_outbox.json")
    }

    private func spool(events: [CKAgentEvent], aggregates: [CKSessionAggregate]) {
        AgentSupportDir.ensure()
        var current = readOutbox()
        current.events.append(contentsOf: events)
        for a in aggregates { current.aggregates.append(a) }
        writeOutbox(current)
    }

    private func readOutbox() -> OutboxFile {
        guard let data = try? Data(contentsOf: outboxURL),
              let f = try? JSONDecoder.cloudKitDate.decode(OutboxFile.self, from: data)
        else { return OutboxFile(events: [], aggregates: []) }
        return f
    }

    private func writeOutbox(_ f: OutboxFile) {
        guard let data = try? JSONEncoder.cloudKitDate.encode(f) else { return }
        try? data.write(to: outboxURL, options: [.atomic])
    }

    private func replayOutbox() {
        let f = readOutbox()
        guard !f.events.isEmpty || !f.aggregates.isEmpty else { return }
        try? FileManager.default.removeItem(at: outboxURL)
        for e in f.events { pendingEvents.append(e) }
        for a in f.aggregates { pendingAggregates[a.sessionKey] = a }
        scheduleFlush()
    }
}

// MARK: - Codable date config

extension JSONEncoder {
    static var cloudKitDate: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

extension JSONDecoder {
    static var cloudKitDate: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

// MARK: - CKRecord mapping

extension CKRecord {
    static func from(_ e: CKAgentEvent) -> CKRecord {
        let r = CKRecord(recordType: CloudKitSchema.RecordType.agentEvent,
                         recordID: CKRecord.ID(recordName: e.recordName))
        r["sessionKey"] = e.sessionKey as CKRecordValue
        r["agent"] = e.agent as CKRecordValue
        if let v = e.agentVariant { r["agentVariant"] = v as CKRecordValue }
        r["macHostname"] = e.macHostname as CKRecordValue
        r["cwdBasename"] = e.cwdBasename as CKRecordValue
        r["cwdHashSuffix"] = e.cwdHashSuffix as CKRecordValue
        r["hookPhase"] = e.hookPhase as CKRecordValue
        r["occurredAt"] = e.occurredAt as CKRecordValue
        r["payloadJSON"] = e.payloadJSON as CKRecordValue
        r["expiresAt"] = e.expiresAt as CKRecordValue
        return r
    }

    static func from(_ n: CKPushNotification) -> CKRecord {
        let r = CKRecord(recordType: CloudKitSchema.RecordType.pushNotification,
                         recordID: CKRecord.ID(recordName: n.recordName))
        r["sessionKey"] = n.sessionKey as CKRecordValue
        r["agent"] = n.agent as CKRecordValue
        r["title"] = n.title as CKRecordValue
        r["body"] = n.body as CKRecordValue
        r["phase"] = n.phase as CKRecordValue
        r["occurredAt"] = n.occurredAt as CKRecordValue
        r["expiresAt"] = n.expiresAt as CKRecordValue
        return r
    }

    static func from(_ a: CKSessionAggregate) -> CKRecord {
        let r = CKRecord(recordType: CloudKitSchema.RecordType.sessionAggregate,
                         recordID: CKRecord.ID(recordName: a.recordName))
        r["sessionKey"] = a.sessionKey as CKRecordValue
        r["agent"] = a.agent as CKRecordValue
        if let v = a.agentVariant { r["agentVariant"] = v as CKRecordValue }
        r["macHostname"] = a.macHostname as CKRecordValue
        r["cwdBasename"] = a.cwdBasename as CKRecordValue
        r["cwdHashSuffix"] = a.cwdHashSuffix as CKRecordValue
        r["startedAt"] = a.startedAt as CKRecordValue
        r["lastEventAt"] = a.lastEventAt as CKRecordValue
        if let e = a.endedAt { r["endedAt"] = e as CKRecordValue }
        r["status"] = a.status.rawValue as CKRecordValue
        if let t = a.currentTool { r["currentTool"] = t as CKRecordValue }
        r["totalToolCalls"] = a.totalToolCalls as CKRecordValue
        r["totalFilesEdited"] = a.totalFilesEdited as CKRecordValue
        r["totalErrors"] = a.totalErrors as CKRecordValue
        if let m = a.model { r["model"] = m as CKRecordValue }
        if let p = a.promptPreview { r["promptPreview"] = p as CKRecordValue }
        r["expiresAt"] = a.expiresAt as CKRecordValue
        if let rid = a.pendingRequestId { r["pendingRequestId"] = rid as CKRecordValue }
        return r
    }
}

// MARK: - Redactor

enum Redactor {
    private static let patterns: [NSRegularExpression] = {
        let raw = [
            #"(?i)aws[_-]?(?:access[_-]?key|secret).{0,5}=\s*\S+"#,
            #"(?i)gh[poursu]_[A-Za-z0-9]{36,}"#,
            #"(?i)sk-[A-Za-z0-9]{20,}"#,
            #"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}"#,
            #"(?i)(?:bearer|authorization|api[_-]?key|token|secret)\s*[:=]\s*[A-Za-z0-9_+/=.-]{16,}"#,
            #"(?i)bearer\s+[A-Za-z0-9_+/=.-]{16,}"#
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static func redact(_ s: String) -> String {
        var out = s
        let placeholder = "«redacted»"
        for re in patterns {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: placeholder)
        }
        return out
    }

    static func redact(event e: CKAgentEvent, minimal: Bool) -> CKAgentEvent {
        let payload: String
        if minimal {
            payload = #"{"minimal":true}"#
        } else {
            payload = redact(e.payloadJSON)
        }
        return CKAgentEvent(
            sessionKey: e.sessionKey, agent: e.agent, agentVariant: e.agentVariant,
            macHostname: e.macHostname, cwdBasename: e.cwdBasename,
            cwdHashSuffix: e.cwdHashSuffix, hookPhase: e.hookPhase,
            occurredAt: e.occurredAt, payloadJSON: payload, expiresAt: e.expiresAt
        )
    }

    static func redact(aggregate a: CKSessionAggregate, minimal: Bool) -> CKSessionAggregate {
        var out = a
        if minimal {
            out.currentTool = nil
            out.model = nil
            out.promptPreview = nil
        } else if let p = a.promptPreview {
            out.promptPreview = redact(p)
        }
        return out
    }
}
