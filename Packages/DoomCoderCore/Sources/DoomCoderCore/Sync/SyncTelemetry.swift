import Foundation
import OSLog

public enum SyncEventKind: String, Sendable, Codable {
    case localEdit
    case enqueued
    case sent
    case pushReceived
    case fetched
    case applied
    case nacked
    case roundTripCompleted
    case engineError
    case stateUpdate
}

public enum SyncSide: String, Sendable, Codable { case mac, ios, unknown }

public struct SyncEvent: Sendable, Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let kind: SyncEventKind
    public let side: SyncSide
    public let recordType: String?
    public let detail: String?
    public let latencyMs: Int?

    public init(id: UUID = UUID(),
                timestamp: Date = Date(),
                kind: SyncEventKind,
                side: SyncSide,
                recordType: String? = nil,
                detail: String? = nil,
                latencyMs: Int? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.side = side
        self.recordType = recordType
        self.detail = detail
        self.latencyMs = latencyMs
    }
}

/// Lightweight, thread-safe ring buffer + os_signpost emitter for diagnosing
/// the iOS↔Mac sync round-trip. Cross-process: the signposts go to OSLog so
/// Instruments can profile across both apps; the in-memory buffer is per-process
/// and is what the in-app Sync Diagnostics view renders.
public final class SyncTelemetry: @unchecked Sendable {
    public static let shared = SyncTelemetry()

    private let lock = NSLock()
    private var buffer: [SyncEvent] = []
    private let capacity = 200

    private let signposter = OSSignposter(subsystem: "com.doomcoder.sync", category: "telemetry")
    private let logger = Logger(subsystem: "com.doomcoder.sync", category: "telemetry")

    // pendingLocalEdits[recordType] = time of the most recent local edit, used to
    // compute the round-trip latency when the matching push/fetch lands.
    private var pendingLocalEdits: [String: Date] = [:]

    private init() {}

    public func record(_ kind: SyncEventKind,
                       side: SyncSide,
                       recordType: String? = nil,
                       detail: String? = nil) {
        let now = Date()
        var latencyMs: Int? = nil

        lock.lock()
        if kind == .localEdit, let rt = recordType {
            pendingLocalEdits[rt] = now
        }
        if kind == .applied, let rt = recordType, let start = pendingLocalEdits.removeValue(forKey: rt) {
            latencyMs = Int(now.timeIntervalSince(start) * 1000)
        }
        let event = SyncEvent(timestamp: now, kind: kind, side: side,
                              recordType: recordType, detail: detail, latencyMs: latencyMs)
        buffer.append(event)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        lock.unlock()

        // DEBUG-ONLY signposts and `logger.debug` lines. The per-record
        // emission is what made the Console unreadable on a 200-record
        // backlog drain: 200 signposts + 200 `logger.debug` lines + 200
        // `NotificationCenter` posts, all from the CKSyncEngine worker
        // thread. Production builds keep ONLY the round-trip-completed
        // `logger.info` line so a user-facing `Console.app` tail is usable.
        // The buffer + `eventRecordedNotification` post remain in DEBUG so
        // the in-app Sync Diagnostics view still has data.
        #if DEBUG
        signposter.emitEvent("sync", "\(kind.rawValue, privacy: .public) side=\(side.rawValue, privacy: .public) rt=\(recordType ?? "-", privacy: .public)")
        if let latencyMs {
            logger.info("sync \(kind.rawValue, privacy: .public) side=\(side.rawValue, privacy: .public) rt=\(recordType ?? "-", privacy: .public) latency=\(latencyMs)ms")
        } else {
            logger.debug("sync \(kind.rawValue, privacy: .public) side=\(side.rawValue, privacy: .public) rt=\(recordType ?? "-", privacy: .public) \(detail ?? "", privacy: .public)")
        }
        #else
        if let latencyMs {
            logger.info("sync applied side=\(side.rawValue, privacy: .public) rt=\(recordType ?? "-", privacy: .public) latency=\(latencyMs)ms")
        }
        #endif
        // Hop NotificationCenter posts to the main queue so SwiftUI @Observable
        // and @State listeners never receive updates on the CKSyncEngine
        // worker thread (which triggers
        // "Publishing changes from background threads is not allowed").
        // Production builds only post the round-trip-completed event (which
        // is the high-signal one — every other `eventRecordedNotification`
        // post is just for the in-app Diagnostics view, which is debug-only).
        let capturedLatency = latencyMs
        let capturedRecordType = recordType
        DispatchQueue.main.async {
            if let ms = capturedLatency {
                NotificationCenter.default.post(name: SyncTelemetry.roundTripCompletedNotification,
                                                object: nil,
                                                userInfo: ["latencyMs": ms,
                                                           "recordType": capturedRecordType ?? ""])
            }
            #if DEBUG
            NotificationCenter.default.post(name: SyncTelemetry.eventRecordedNotification, object: event)
            #endif
        }
    }

    public func snapshot() -> [SyncEvent] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    public func lastRoundTripLatencyMs() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return buffer.reversed().first(where: { $0.latencyMs != nil })?.latencyMs
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll()
        pendingLocalEdits.removeAll()
    }

    public static let eventRecordedNotification = Notification.Name("SyncTelemetry.eventRecorded")
    public static let roundTripCompletedNotification = Notification.Name("SyncTelemetry.roundTripCompleted")
}
