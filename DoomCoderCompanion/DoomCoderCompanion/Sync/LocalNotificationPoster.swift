// LocalNotificationPoster.swift — DoomCoder Companion
// Posts rich LOCAL notifications when the in-app CKSyncEngine delivers a
// new NotificationLogRecord. This is the primary rich-content path — it
// works even if the Notification Service Extension is bypassed.

import UserNotifications
import DoomCoderCore

@MainActor
enum LocalNotificationPoster {

    /// Post a rich local notification for a freshly-received NotificationLogRecord.
    /// Safe to call multiple times with the same record — deduplicated by notifId.
    static func post(_ r: NotificationLogRecord) {
        let dedupKey = "localPosted.\(r.notifId)"
        guard AppGroupCache.defaults.object(forKey: dedupKey) == nil else { return }
        AppGroupCache.defaults.set(true, forKey: dedupKey)

        let content = UNMutableNotificationContent()
        content.title    = r.title
        content.body     = r.body
        content.subtitle = "On \(r.macName)"
        content.sound    = .default
        content.threadIdentifier = r.sessionKey

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
           let attachment = try? UNNotificationAttachment(identifier: "icon", url: iconURL) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: "local.\(r.notifId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { err in
            if let err { print("[LocalNotifPoster] error for \(r.notifId): \(err)") }
        }
    }
}
