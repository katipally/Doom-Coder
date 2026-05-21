import Foundation
import AppKit
import CloudKit
import OSLog
import DoomCoderCore

/// Applies remote-control commands written by the iOS companion. Invoked by
/// the CloudKit subscription path and on launch (for any commands that
/// arrived while the Mac was asleep / offline).
///
/// Each verb maps to an existing piece of Mac state. We never apply a
/// command more than once: `appliedAt` is the idempotency token. If the
/// record already has `appliedAt`, we no-op.
@MainActor
enum ControlCommandRouter {

    private static let logger = Logger(subsystem: "com.doomcoder", category: "cmd-router")

    /// Routes a command record. Stamps `appliedAt` + `result` back through
    /// the sync engine so iOS can reconcile.
    static func apply(_ cmd: ControlCommandRecord) async {
        guard cmd.appliedAt == nil else { return }
        // Multi-Mac safety: ignore commands not addressed to this Mac.
        let myId = CloudKitSyncEngine.shared.macId
        guard cmd.macId == myId else { return }

        var updated = cmd
        updated.appliedAt = Date()
        do {
            let resultText = try await dispatch(verb: cmd.verb, args: cmd.args)
            updated.result = resultText
        } catch {
            updated.error = error.localizedDescription
            logger.error("cmd \(cmd.verb.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        CloudKitSyncEngine.shared.acknowledgeCommand(updated)
    }

    /// Pulls any pending commands from CloudKit (used on launch and on
    /// silent-push wakeup). Idempotent.
    static func drainPending() async {
        guard CloudKitSyncEngine.shared.isAvailable else { return }
        let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
        let db = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName,
                                     ownerName: CKCurrentUserDefaultName)
        let predicate = NSPredicate(format: "appliedAt == nil")
        let query = CKQuery(recordType: ControlCommandRecord.recordType, predicate: predicate)
        do {
            let (matches, _) = try await db.records(matching: query, inZoneWith: zoneID)
            for (_, res) in matches {
                if case .success(let rec) = res, let cmd = ControlCommandRecord(rec) {
                    await apply(cmd)
                }
            }
        } catch {
            logger.notice("drainPending: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Verb dispatch

    private static func dispatch(verb: ControlCommandRecord.Verb, args: [String: Any]) async throws -> String {
        switch verb {
        case .setSetting:
            return "ok"   // settings live in the Settings record itself

        case .toggleMaster:
            SleepManager.shared.toggle()
            return "master=\(SleepManager.shared.isActive)"

        case .enableSleep:
            SleepManager.shared.enable()
            return "enabled"

        case .disableSleep:
            SleepManager.shared.disable()
            return "disabled"

        case .setMode:
            guard let raw = args["mode"] as? String,
                  let mode = DoomCoderMode(rawValue: raw)
            else { throw RouterError.badArgs("mode") }
            SleepManager.shared.mode = mode
            return "mode=\(mode.rawValue)"

        case .setSessionTimer:
            guard let h = args["hours"] as? Int else { throw RouterError.badArgs("hours") }
            SleepManager.shared.sessionTimerHours = h
            return "timer=\(h)h"

        case .pauseAgent:
            guard let raw = args["agent"] as? String,
                  let agent = TrackedAgent(rawValue: raw)
            else { throw RouterError.badArgs("agent") }
            TrackingStore.setEnabled(agent, false)
            return "paused=\(agent.rawValue)"

        case .resumeAgent:
            guard let raw = args["agent"] as? String,
                  let agent = TrackedAgent(rawValue: raw)
            else { throw RouterError.badArgs("agent") }
            TrackingStore.setEnabled(agent, true)
            return "resumed=\(agent.rawValue)"

        case .clearSession:
            guard let key = args["sessionKey"] as? String else { throw RouterError.badArgs("sessionKey") }
            // No public clearSession — drop in-memory aggregate by re-emitting.
            // We'd need a manager API for this; for now log and ack.
            logger.notice("clearSession requested for \(key, privacy: .public) — best-effort no-op")
            return "ok"

        case .sendTestNotification:
            let channel = (args["channel"] as? String) ?? "macOS"
            if channel == "macOS" {
                _ = await NotificationDispatcher.shared.sendTest(channel: .macOS)
            } else {
                // iOS test = create a NotificationLog record with phase=other.
                CloudKitSyncEngine.shared.publishNotification(
                    sessionKey: "test::\(UUID().uuidString)",
                    agent: TrackedAgent.claude.rawValue,
                    phase: NormalizedEventPhase.other.rawValue,
                    event: "test",
                    title: "DoomCoder · test",
                    body: "iOS notifications are working ✨",
                    channel: "iOS", success: true, ts: Date(),
                    lastTool: nil, cwdBase: nil
                )
            }
            return "sent"

        case .restartHookSocket:
            HookSocketListener.shared.stop()
            HookSocketListener.shared.start { env in
                Task { @MainActor in AgentTrackingManager.shared.ingest(env) }
            }
            return "restarted"

        case .quitDoomCoder:
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
            return "quitting"
        }
    }

    enum RouterError: Error, LocalizedError {
        case badArgs(String)
        var errorDescription: String? {
            switch self {
            case .badArgs(let k): return "missing or invalid arg: \(k)"
            }
        }
    }
}
