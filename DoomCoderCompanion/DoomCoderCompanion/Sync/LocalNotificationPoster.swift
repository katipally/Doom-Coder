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
        // Guard 1: Only notify for RECENT events. When CKSyncEngine does a full
        // zone fetch on first launch or state reset, it delivers ALL historical
        // records. Without this check, every historical record fires a spurious
        // notification banner as soon as the app opens. 5 minutes is generous
        // enough to cover CloudKit propagation delays while excluding records
        // from hours/days ago.
        guard r.ts > Date(timeIntervalSinceNow: -300) else { return }

        // Guard 2: Per-notifId dedup so we never post the same event twice,
        // even if the record is delivered by both CKDatabaseSubscription and
        // CKQuerySubscription paths.
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
