// NotificationService.swift — DoomCoder Companion NSE
// Notification Service Extension. Intercepts mutable CloudKit push payloads
// before they are displayed and enriches them with the rich title/body
// pre-computed by the Mac (stored as CKRecord fields) plus agent icon.

import UserNotifications
import DoomCoderCore

class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        self.bestAttemptContent = mutable

        // ── Debug dump ──────────────────────────────────────────────────────
        // Write the raw push payload to App Group so the companion app can
        // display it in a Debug tab. Remove once NSE is confirmed working.
        dumpPayload(request.content.userInfo)

        // ── Field extraction ────────────────────────────────────────────────
        // CloudKit push payload for CKQuerySubscription with desiredKeys:
        //   userInfo["ck"]["qry"]["af"][fieldName]["value"]
        // "af" = additional fields. NOT "rec.fields". NOT "qry.fields".
        let userInfo = request.content.userInfo
        func field(_ name: String) -> String? {
            guard
                let ck  = userInfo["ck"]  as? [String: Any],
                let qry = ck["qry"]       as? [String: Any],
                let af  = qry["af"]       as? [String: Any],
                let fld = af[name]        as? [String: Any],
                let val = fld["value"]    as? String
            else { return nil }
            return val
        }

        // v6 desiredKeys: agent, title, body, sessionKey, phase
        // title + body are pre-computed by the Mac (rich copy already done).
        let richTitle  = field("title")
        let richBody   = field("body")
        let agentRaw   = field("agent")
        let phaseRaw   = field("phase")
        let sessionKey = field("sessionKey")
        // macName not in desiredKeys — read from App Group cache.
        let macName    = AppGroupCache.defaults.string(forKey: "cache.primaryMacName")

        // ── Enrich title / body ─────────────────────────────────────────────
        if let t = richTitle, !t.isEmpty { mutable.title = t }
        if let b = richBody,  !b.isEmpty { mutable.body  = b }

        // ── Subtitle ────────────────────────────────────────────────────────
        if let mn = macName, !mn.isEmpty { mutable.subtitle = "On \(mn)" }

        // ── Thread identifier ────────────────────────────────────────────────
        if let sk = sessionKey { mutable.threadIdentifier = sk }

        // ── Interruption level ───────────────────────────────────────────────
        if let p = phaseRaw.flatMap({ NormalizedEventPhase(rawValue: $0) }) {
            switch p.iOSInterruptionLevel {
            case .passive:       mutable.interruptionLevel = .passive
            case .active:        mutable.interruptionLevel = .active
            case .timeSensitive: mutable.interruptionLevel = .timeSensitive
            case .critical:      mutable.interruptionLevel = .critical
            }
        }

        // ── Agent icon attachment ────────────────────────────────────────────
        if let slug = agentRaw.flatMap({ TrackedAgent(rawValue: $0) })?.iconSlug,
           let iconURL = AppGroupCache.iconURL(slug: slug),
           let attachment = try? UNNotificationAttachment(identifier: "icon", url: iconURL) {
            mutable.attachments = [attachment]
        }

        contentHandler(mutable)
    }

    override func serviceExtensionTimeWillExpire() {
        if let content = bestAttemptContent { contentHandler?(content) }
    }

    // MARK: - Debug helpers

    private func dumpPayload(_ userInfo: [AnyHashable: Any]) {
        guard let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier:
                            CloudKitConstants.appGroupIdentifier) else { return }
        guard let data = try? JSONSerialization.data(
            withJSONObject: userInfo,
            options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(
            to: dir.appendingPathComponent("nse_debug.json"),
            options: .atomic)
    }
}
