import Foundation
import UserNotifications

@MainActor
final class ApprovalResponder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ApprovalResponder()
    private override init() { super.init() }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let requestId = info["requestId"] as? String,
              let toolName = info["toolName"] as? String,
              let agent = info["agent"] as? String else { return }
        let decision: String
        switch response.actionIdentifier {
        case "APPROVE": decision = "approve"
        case "DENY": decision = "deny"
        case "ALWAYS":
            decision = "always"
            AlwaysAllowStore.add(agent: agent, tool: toolName)
        default: return
        }
        let uuid = DevicePresenceUpdater.shared.deviceUUID()
        try? await CloudKitClient.shared.writeApprovalResponse(requestId: requestId, decision: decision, deviceUUID: uuid)
    }

    func respond(requestId: String, agent: String, tool: String, decision: String) async {
        if decision == "always" { AlwaysAllowStore.add(agent: agent, tool: tool) }
        let uuid = DevicePresenceUpdater.shared.deviceUUID()
        try? await CloudKitClient.shared.writeApprovalResponse(requestId: requestId, decision: decision, deviceUUID: uuid)
    }
}

enum AlwaysAllowStore {
    private static let key = "approvals.alwaysAllow.v1"
    static func add(agent: String, tool: String) {
        var set = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        set.insert("\(agent)::\(tool)")
        UserDefaults.standard.set(Array(set), forKey: key)
    }
    static func contains(agent: String, tool: String) -> Bool {
        let set = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        return set.contains("\(agent)::\(tool)")
    }
}
