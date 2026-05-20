// NotificationService.swift — DoomCoder Companion NSE
// Notification Service Extension. Intercepts mutable CloudKit push payloads
// before they are displayed, enriches title/body through NotificationCopy, sets
// the interruption level from NormalizedEventPhase, and attaches per-agent icons
// from the shared App Group icon cache.

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

        // CloudKit silent-push payloads for CKQuerySubscriptions are nested under
        // "ck" → "qry" → "rec" → "fields" where each value is {"value": <v>}.
        let userInfo = request.content.userInfo
        func field(_ name: String) -> String? {
            guard
                let ck  = userInfo["ck"]  as? [String: Any],
                let qry = ck["qry"]       as? [String: Any],
                let rec = qry["rec"]      as? [String: Any],
                let flds = rec["fields"]  as? [String: Any],
                let fld = flds[name]      as? [String: Any],
                let val = fld["value"]    as? String
            else { return nil }
            return val
        }

        let agentRaw   = field("agent")
        let phaseRaw   = field("phase")
        let tool       = field("lastTool")   // CK field key is "lastTool", not "tool"
        let cwdBase    = field("cwdBase")
        let sessionKey = field("sessionKey")
        let macName    = field("macName")
        let rawTitle   = field("title")
        let rawBody    = field("body")

        let agent = agentRaw.flatMap { TrackedAgent(rawValue: $0) }
        let phase = phaseRaw.flatMap { NormalizedEventPhase(rawValue: $0) }

        // Enrich title + body through NotificationCopy helpers when we have
        // enough context; fall back to the Mac-supplied strings otherwise.
        if let a = agent, let p = phase {
            let ctx = NotificationCopy.EventContext(
                agent: a,
                phase: p,
                lastTool: tool,
                cwdBase: cwdBase
            )
            mutable.title = NotificationCopy.title(ctx)
            mutable.body  = NotificationCopy.body(ctx)
        } else {
            // Use whatever the Mac embedded in the payload.
            if let t = rawTitle { mutable.title = t }
            if let b = rawBody  { mutable.body  = b }
        }

        // Subtitle: "On <macName>" when available.
        if let mn = macName, !mn.isEmpty { mutable.subtitle = "On \(mn)" }

        // Interruption level from phase.
        if let p = phase {
            mutable.interruptionLevel = interruptionLevel(from: p)
        }

        // Thread identifier groups alerts by session in the notification centre.
        if let sk = sessionKey { mutable.threadIdentifier = sk }

        // Agent icon attachment from shared App Group cache.
        if let slug = agent?.iconSlug,
           let iconURL = AppGroupCache.iconURL(slug: slug),
           let attachment = try? UNNotificationAttachment(identifier: "icon", url: iconURL) {
            mutable.attachments = [attachment]
        }

        contentHandler(mutable)
    }

    override func serviceExtensionTimeWillExpire() {
        // Deliver the best-attempt content we have built so far.
        if let content = bestAttemptContent {
            contentHandler?(content)
        }
    }

    // MARK: - Helpers

    private func interruptionLevel(
        from phase: NormalizedEventPhase
    ) -> UNNotificationInterruptionLevel {
        switch phase.iOSInterruptionLevel {
        case .passive:       return .passive
        case .active:        return .active
        case .timeSensitive: return .timeSensitive
        case .critical:      return .critical
        }
    }
}
