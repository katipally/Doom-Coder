// LocalNotificationPoster.swift — DoomCoder Companion
// Posts rich LOCAL notifications when the in-app CKSyncEngine delivers a
// new NotificationLogRecord. This is the primary rich-content path — it
// works even if the Notification Service Extension is bypassed.
//
// The CKQuerySubscription push still fires first (guaranteed APNs delivery)
// and the NSE enriches it when possible. The local post here runs a few
// seconds later and updates the delivered notification in the notification
// centre via matching requestIdentifier.

import UserNotifications
import DoomCoderCore

@MainActor
enum LocalNotificationPoster {

    /// Post a rich local notification for a freshly-received NotificationLogRecord.
    /// Safe to call multiple times with the same record — deduplicated by notifId.
    static func post(_ r: NotificationLogRecord) {
        let dedupKey = "localPosted.\(r.notifId)"
        // Skip if we already posted a local notif for this record.
        guard AppGroupCache.defaults.object(forKey: dedupKey) == nil else { return }
        AppGroupCache.defaults.set(true, forKey: dedupKey)

        let content = UNMutableNotificationContent()
        // Use the Mac-precomputed rich strings directly.
        content.title    = r.title
        content.body     = r.body
        content.subtitle = "On \(r.macName)"
        content.sound    = .default
        content.threadIdentifier = r.sessionKey

        // Interruption level from phase.
        if let phase = NormalizedEventPhase(rawValue: r.phase) {
            switch phase.iOSInterruptionLevel {
            case .passive:       content.interruptionLevel = .passive
            case .active:        content.interruptionLevel = .active
            case .timeSensitive: content.interruptionLevel = .timeSensitive
            case .critical:      content.interruptionLevel = .critical
            }
        }

        // Agent icon from App Group cache (downloaded by AgentIconFetcher).
        if let slug = TrackedAgent(rawValue: r.agent)?.iconSlug,
           let iconURL = AppGroupCache.iconURL(slug: slug),
           let attachment = try? UNNotificationAttachment(
                identifier: "icon", url: iconURL,
                options: [UNNotificationAttachmentOptionsThumbnailClippingRectKey:
                              CGRect(x: 0, y: 0, width: 1, height: 1) as AnyObject]
           ) {
            content.attachments = [attachment]
        }

        // Use "local.<notifId>" as the request identifier. If the CKQuerySub
        // push already delivered a notification, iOS will update it in the
        // notification centre (same-category replacement is not guaranteed
        // cross-process, but it avoids silent duplication in most cases).
        let request = UNNotificationRequest(
            identifier: "local.\(r.notifId)",
            content: content,
            trigger: nil    // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { err in
            if let err { print("[LocalNotifPoster] error for \(r.notifId): \(err)") }
        }
    }
}
