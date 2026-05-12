import Foundation
import CloudKit
import UIKit

@MainActor
final class CloudKitSubscriptionHandler {
    static let shared = CloudKitSubscriptionHandler()
    private let defaults = UserDefaults.standard
    private let keyRegistered = "ck.subscriptions.registered.v1"
    private init() {}

    func registerAll() async {
        if defaults.bool(forKey: keyRegistered) { return }
        let db = CloudKitClient.shared.db
        let subs: [CKSubscription] = [
            buildSubscription(recordType: CloudKitSchema.RecordType.sessionAggregate,
                              subscriptionId: "sub.sessionaggregate.v1",
                              options: [.firesOnRecordCreation, .firesOnRecordUpdate]),
            buildSubscription(recordType: CloudKitSchema.RecordType.approvalRequest,
                              subscriptionId: "sub.approvalrequest.v1",
                              options: [.firesOnRecordCreation]),
            buildSubscription(recordType: CloudKitSchema.RecordType.userSettings,
                              subscriptionId: "sub.usersettings.v1",
                              options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        ]
        do {
            _ = try await db.modifySubscriptions(saving: subs, deleting: [])
            defaults.set(true, forKey: keyRegistered)
        } catch {
            // Will retry on next launch
        }
    }

    private func buildSubscription(recordType: String,
                                   subscriptionId: String,
                                   options: CKQuerySubscription.Options) -> CKQuerySubscription {
        let sub = CKQuerySubscription(recordType: recordType,
                                      predicate: NSPredicate(value: true),
                                      subscriptionID: subscriptionId,
                                      options: options)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        info.shouldBadge = false
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
            let rec = try await CloudKitClient.shared.db.record(for: CKRecord.ID(recordName: recordName))
            switch rec.recordType {
            case CloudKitSchema.RecordType.sessionAggregate:
                if let agg = decodeAggregate(rec) {
                    SessionStore.shared.upsert(agg)
                    await LiveActivityManager.shared.update(with: agg)
                }
            case CloudKitSchema.RecordType.approvalRequest:
                await NotificationDispatcher.shared.deliverApproval(recordName: recordName, record: rec)
            case CloudKitSchema.RecordType.userSettings:
                SettingsSyncer.shared.applyRemote(rec)
            default: break
            }
        } catch {
            // ignore push for already-deleted records
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
            expiresAt: (rec["expiresAt"] as? Date) ?? Date().addingTimeInterval(7 * 86400)
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
