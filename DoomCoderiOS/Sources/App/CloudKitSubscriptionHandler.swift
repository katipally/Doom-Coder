import Foundation
import CloudKit
import OSLog
import UIKit

private let ckLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DoomCoderiOS", category: "CloudKitSubs")

@MainActor
final class CloudKitSubscriptionHandler {
    static let shared = CloudKitSubscriptionHandler()
    private let defaults = UserDefaults.standard
    private let keyRegistered = "ck.subscriptions.registered.v5"
    private init() {}

    func registerAll() async {
        if defaults.bool(forKey: keyRegistered) { return }
        // v4: split aggregate into two subscriptions:
        //   - alert sub: fires only for waitingApproval/failed/completed — alert push via NSE
        //   - silent sub: fires for running — silent push to wake app for LiveActivity updates
        // This prevents spammy running-state notifications (every tool call = one push).
        let subs: [CKSubscription] = [
            buildAggregateAlertSubscription(),
            buildAggregateSilentSubscription(),
            buildPushNotificationAlertSubscription(),
            buildSubscription(recordType: CloudKitSchema.RecordType.approvalRequest,
                              subscriptionId: "sub.approvalrequest.v4",
                              desiredKeys: ["agent", "cwdBasename", "toolName", "toolArgsJSON", "sessionKey"]),
            buildSubscription(recordType: CloudKitSchema.RecordType.userSettings,
                              subscriptionId: "sub.usersettings.v4",
                              desiredKeys: nil)
        ]
        do {
            try await CloudKitClient.shared.modifySubscriptions(saving: subs)
            defaults.set(true, forKey: keyRegistered)
            ckLog.info("CloudKit subscriptions registered successfully")
        } catch {
            ckLog.error("CloudKit subscription registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Force re-registration (e.g., after account change or explicit user reset).
    func forceReRegister() async {
        defaults.removeObject(forKey: keyRegistered)
        await registerAll()
    }

    /// Alert subscription — only fires for actionable states (not running).
    /// The NSE intercepts and builds a rich notification. Alert pushes are
    /// always delivered by APNs regardless of Low Power Mode or app state.
    private func buildAggregateAlertSubscription() -> CKQuerySubscription {
        let predicate = NSPredicate(format: "status IN %@",
                                    ["waitingApproval", "failed", "completed"])
        let sub = CKQuerySubscription(
            recordType: CloudKitSchema.RecordType.sessionAggregate,
            predicate: predicate,
            subscriptionID: "sub.sessionaggregate.alert.v4",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        let info = CKSubscription.NotificationInfo()
        info.alertBody = "Agent update — tap to view"  // NSE overwrites this
        info.shouldSendMutableContent = true            // allows NSE to intercept
        info.shouldSendContentAvailable = true          // wakes app for LiveActivity
        info.shouldBadge = false
        info.desiredKeys = [
            "status", "agent", "cwdBasename", "currentTool",
            "sessionKey", "pendingRequestId",
            "totalToolCalls", "totalFilesEdited"
        ]
        sub.notificationInfo = info
        return sub
    }

    /// Silent subscription — fires for running-state updates.
    /// Wakes the app in background to update SessionStore and LiveActivity.
    /// No visible notification is shown for routine tool calls.
    private func buildAggregateSilentSubscription() -> CKQuerySubscription {
        let predicate = NSPredicate(format: "status = %@", "running")
        let sub = CKQuerySubscription(
            recordType: CloudKitSchema.RecordType.sessionAggregate,
            predicate: predicate,
            subscriptionID: "sub.sessionaggregate.silent.v4",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true  // silent push only
        info.shouldBadge = false
        info.desiredKeys = [
            "status", "agent", "cwdBasename", "currentTool",
            "sessionKey", "totalToolCalls", "totalFilesEdited"
        ]
        sub.notificationInfo = info
        return sub
    }

    /// Alert subscription for `PushNotification` records written by macOS NotificationRouter.
    /// Fires an alert push for every agent notification the Mac would show locally.
    /// NSE intercepts and renders title/body with default sound.
    private func buildPushNotificationAlertSubscription() -> CKQuerySubscription {
        let sub = CKQuerySubscription(
            recordType: CloudKitSchema.RecordType.pushNotification,
            predicate: NSPredicate(value: true),
            subscriptionID: "sub.pushnotification.alert.v5",
            options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.alertBody = "Agent update"         // NSE overwrites this
        info.shouldSendMutableContent = true    // allows NSE to intercept
        info.shouldSendContentAvailable = false // pure alert push, no background wake needed
        info.shouldBadge = false
        info.desiredKeys = ["title", "body", "agent", "phase", "sessionKey"]
        sub.notificationInfo = info
        return sub
    }

    private func buildSubscription(recordType: String,
                                   subscriptionId: String,
                                   desiredKeys: [String]?) -> CKQuerySubscription {
        let options: CKQuerySubscription.Options = [.firesOnRecordCreation]
        let sub = CKQuerySubscription(recordType: recordType,
                                      predicate: NSPredicate(value: true),
                                      subscriptionID: subscriptionId,
                                      options: options)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        info.shouldBadge = false
        if let keys = desiredKeys { info.desiredKeys = keys }
        sub.notificationInfo = info
        return sub
    }
}

@MainActor
final class PushReceiver {
    static let shared = PushReceiver()
    private init() {}

    func handle(userInfo: [AnyHashable: Any]) async {
        guard let aps = userInfo["aps"] as? [String: Any],
              let ck = userInfo["ck"] as? [String: Any] else { return }
        _ = aps
        if let qry = ck["qry"] as? [String: Any], let rid = qry["rid"] as? String {
            await routeChangedRecord(recordName: rid, ck: ck)
        }
    }

    private func routeChangedRecord(recordName: String, ck: [String: Any]) async {
        do {
            guard let rec = try await CloudKitClient.shared.record(for: CKRecord.ID(recordName: recordName)) else { return }
            switch rec.recordType {
            case CloudKitSchema.RecordType.pushNotification:
                // App is in the foreground — NSE won't fire. Show the notification directly.
                if let title = rec["title"] as? String, let body = rec["body"] as? String {
                    await NotificationDispatcher.shared.deliverGeneric(
                        title: title, body: body, sessionKey: rec["sessionKey"] as? String)
                }
            case CloudKitSchema.RecordType.sessionAggregate:
                if let agg = decodeAggregate(rec) {
                    // Capture previous status before upsert so we can detect transitions.
                    let prevStatus = SessionStore.shared.liveSessions.first { $0.id == agg.sessionKey }?.status
                    SessionStore.shared.upsert(agg)
                    await LiveActivityManager.shared.update(with: agg)
                    await dispatchStatusNotification(agg: agg, previousStatus: prevStatus)
                }
            case CloudKitSchema.RecordType.approvalRequest:
                // macOS does not write ApprovalRequest CKRecords; approvals come via sessionAggregate.
                // Kept here for forward-compatibility.
                await NotificationDispatcher.shared.deliverApproval(recordName: recordName, record: rec)
            case CloudKitSchema.RecordType.userSettings:
                SettingsSyncer.shared.applyRemote(rec)
            default: break
            }
        } catch {
            ckLog.debug("Push record fetch failed (likely already deleted): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func dispatchStatusNotification(agg: CKSessionAggregate,
                                            previousStatus: CKSessionAggregate.Status?) async {
        let settings = IOSUserSettings.shared
        switch agg.status {
        case .waitingApproval where previousStatus != .waitingApproval:
            guard settings.notifyApprovals else { return }
            await NotificationDispatcher.shared.deliverApprovalFromAggregate(agg)
        case .failed where previousStatus == .running || previousStatus == .waitingApproval:
            guard settings.notifyFailures else { return }
            let durationMs = Int(agg.lastEventAt.timeIntervalSince(agg.startedAt) * 1000)
            await NotificationDispatcher.shared.deliverFailure(
                agent: agg.agent, sessionKey: agg.sessionKey, cwd: agg.cwdBasename,
                tool: agg.currentTool ?? "unknown", exitCode: -1, durationMs: durationMs)
        case .completed where previousStatus == .running || previousStatus == .waitingApproval:
            guard settings.notifySessionSummaries else { return }
            let durationSec = Int(agg.lastEventAt.timeIntervalSince(agg.startedAt))
            await NotificationDispatcher.shared.deliverSummary(
                agent: agg.agent, sessionKey: agg.sessionKey, cwd: agg.cwdBasename,
                toolCalls: agg.totalToolCalls, filesEdited: agg.totalFilesEdited, durationSec: durationSec)
        default: break
        }
    }

    private func decodeAggregate(_ rec: CKRecord) -> CKSessionAggregate? {
        guard let sessionKey = rec["sessionKey"] as? String,
              let agent = rec["agent"] as? String,
              let macHostname = rec["macHostname"] as? String,
              let cwdBasename = rec["cwdBasename"] as? String,
              let startedAt = rec["startedAt"] as? Date,
              let lastEventAt = rec["lastEventAt"] as? Date,
              let statusRaw = rec["status"] as? String,
              let status = CKSessionAggregate.Status(rawValue: statusRaw) else { return nil }
        return CKSessionAggregate(
            sessionKey: sessionKey,
            agent: agent,
            agentVariant: rec["agentVariant"] as? String,
            macHostname: macHostname,
            cwdBasename: cwdBasename,
            cwdHashSuffix: (rec["cwdHashSuffix"] as? String) ?? "",
            startedAt: startedAt,
            lastEventAt: lastEventAt,
            endedAt: rec["endedAt"] as? Date,
            status: status,
            currentTool: rec["currentTool"] as? String,
            totalToolCalls: (rec["totalToolCalls"] as? Int) ?? 0,
            totalFilesEdited: (rec["totalFilesEdited"] as? Int) ?? 0,
            totalErrors: (rec["totalErrors"] as? Int) ?? 0,
            model: rec["model"] as? String,
            promptPreview: rec["promptPreview"] as? String,
            toolArgsPreview: rec["toolArgsPreview"] as? String,
            expiresAt: (rec["expiresAt"] as? Date) ?? Date().addingTimeInterval(7 * 86400),
            pendingRequestId: rec["pendingRequestId"] as? String
        )
    }
}

@MainActor
final class DevicePresenceUpdater {
    static let shared = DevicePresenceUpdater()
    private init() {}

    func heartbeat() async {
        let uuid = deviceUUID()
        let name = UIDevice.current.name
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.0.0"
        try? await CloudKitClient.shared.writeDevicePresence(uuid: uuid, name: name, appVersion: version)
    }

    func deviceUUID() -> String {
        let key = "device.uuid.v1"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}
