// NotificationService.swift — DoomCode Companion NSE
// Notification Service Extension. Intercepts mutable CloudKit push payloads
// before they are displayed and enriches them with the rich title/body
// pre-computed by the Mac (stored as CKRecord fields) plus agent icon.

import UserNotifications
import DoomCodeCore

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

        // v8 desiredKeys: agent, title, body, sessionKey, phase, macName
        // title + body are pre-computed by the Mac via NotificationCopy.
        let richTitle  = field("title")
        let richBody   = field("body")
        let agentRaw   = field("agent")
        let phaseRaw   = field("phase")
        let sessionKey = field("sessionKey")
        let macName    = field("macName")

        // ── Title / body resolution ─────────────────────────────────────────
        // With v8 subscriptions APNs delivers the Mac-rendered title and body
        // directly in `aps.alert.title` / `aps.alert.body` (via
        // titleLocalizationKey="%@" + args=["title"] in CompanionSyncEngine).
        // The OS pre-populates request.content.title / body with those
        // values, so the NSE just needs to keep them.
        //
        // Fallback chain (in order):
        //   1. request.content.title/body — APNs-substituted CKRecord values
        //   2. additional-fields ("af") map — same CKRecord values, manually
        //      extracted; covers the case where the localization-arg
        //      substitution fails on older iOS or quirky payloads.
        //   3. NotificationCopy re-render from (agent, phase) — last-ditch
        //      reconstruction if the Mac fields somehow weren't delivered.
        // We deliberately do NOT fall through to literal "DoomCode · Update"
        // anymore. If steps 1–3 all fail we let the OS show whatever it
        // already has, which is at minimum a non-blank space from APNs.
        let preTitle = mutable.title
        let preBody  = mutable.body
        let agent = agentRaw.flatMap { TrackedAgent(rawValue: $0) }
        let phase = phaseRaw.flatMap { NormalizedEventPhase(rawValue: $0) }
        let copyContext: NotificationCopy.EventContext? = {
            guard let agent, let phase else { return nil }
            return NotificationCopy.EventContext(agent: agent, phase: phase)
        }()

        if preTitle.isEmpty || preTitle == " " {
            if let t = richTitle, !t.isEmpty {
                mutable.title = t
            } else if let ctx = copyContext {
                mutable.title = NotificationCopy.title(ctx)
            }
        }
        if preBody.isEmpty || preBody == " " {
            if let b = richBody, !b.isEmpty {
                mutable.body = b
            } else if let ctx = copyContext {
                mutable.body = NotificationCopy.body(ctx)
            }
        }

        // ── Subtitle ("On <MacName>") ────────────────────────────────────────
        // Restored per user request. Helps disambiguate when more than one Mac
        // is paired. Set when we have a macName AND the system didn't already
        // pre-populate a subtitle (e.g. via aps.alert.subtitle or a previous
        // local-notification pass through the same device).
        if let mac = macName, !mac.isEmpty, mutable.subtitle.isEmpty {
            mutable.subtitle = "On \(mac)"
        }

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
        if let agent {
            let bundleURL = Bundle(for: NotificationService.self)
                .url(forResource: agent.bundledAssetName, withExtension: "png")
            let iconURL = bundleURL ?? AppGroupCache.iconURL(slug: agent.iconSlug)
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
