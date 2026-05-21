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

        // ── Debug dump (DEBUG-only) ─────────────────────────────────────────
        #if DEBUG
        dumpPayload(request.content.userInfo)
        #endif

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

        // v7 desiredKeys: agent, title, body, sessionKey, phase
        // title + body are pre-computed by the Mac via NotificationCopy.
        let richTitle  = field("title")
        let richBody   = field("body")
        let agentRaw   = field("agent")
        let phaseRaw   = field("phase")
        let sessionKey = field("sessionKey")

        // ── Always render title / body ──────────────────────────────────────
        // APNs already delivered `aps.alert = " "` (CompanionSyncEngine sets
        // the placeholder so iOS will invoke the NSE at all). We MUST replace
        // both fields with non-empty strings — returning empty content does
        // NOT suppress the banner; the OS still shows the placeholder space.
        // Fallback chain: push field → re-render via NotificationCopy from
        // (agent, phase) → literal "DoomCoder · update".
        let agent = agentRaw.flatMap { TrackedAgent(rawValue: $0) }
        let phase = phaseRaw.flatMap { NormalizedEventPhase(rawValue: $0) }
        let copyContext: NotificationCopy.EventContext? = {
            guard let agent, let phase else { return nil }
            return NotificationCopy.EventContext(agent: agent, phase: phase)
        }()

        if let t = richTitle, !t.isEmpty {
            mutable.title = t
        } else if let ctx = copyContext {
            mutable.title = NotificationCopy.title(ctx)
        } else {
            mutable.title = "DoomCoder"
        }
        if let b = richBody, !b.isEmpty {
            mutable.body = b
        } else if let ctx = copyContext {
            mutable.body = NotificationCopy.body(ctx)
        } else {
            mutable.body = "Update"
        }

        // Subtitle is intentionally NOT set — users found "On <MacName>" noisy.

        // ── Thread identifier ────────────────────────────────────────────────
        if let sk = sessionKey { mutable.threadIdentifier = sk }

        // ── Interruption level ───────────────────────────────────────────────
        if let p = phase {
            switch p.iOSInterruptionLevel {
            case .passive:       mutable.interruptionLevel = .passive
            case .active:        mutable.interruptionLevel = .active
            case .timeSensitive: mutable.interruptionLevel = .timeSensitive
            case .critical:      mutable.interruptionLevel = .critical
            }
        }

        // ── Agent icon attachment ────────────────────────────────────────────
        // Bundle (NSE target) → App Group cache. Bundle wins so a freshly
        // installed iOS build always has icons even before the first
        // CloudKit AgentIcon fetch resolves.
        if let slug = agent?.iconSlug {
            let bundleURL = Bundle(for: NotificationService.self)
                .url(forResource: slug, withExtension: "png")
            let iconURL = bundleURL ?? AppGroupCache.iconURL(slug: slug)
            if let url = iconURL,
               let attachment = try? UNNotificationAttachment(identifier: "icon", url: url) {
                mutable.attachments = [attachment]
            }
        }

        contentHandler(mutable)
    }

    override func serviceExtensionTimeWillExpire() {
        if let content = bestAttemptContent { contentHandler?(content) }
    }

    // MARK: - Debug helpers

    #if DEBUG
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
    #endif
}
