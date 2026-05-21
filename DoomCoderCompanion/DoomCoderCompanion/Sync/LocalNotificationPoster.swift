// LocalNotificationPoster.swift — DoomCoder Companion
//
// DEPRECATED in v3.0.
//
// This file used to post a second, parallel local notification for every
// NotificationLogRecord that arrived through CKSyncEngine. Combined with the
// Notification Service Extension's banner on the CKQuerySubscription push,
// users saw TWO banners per event and a hardcoded "On <MacName>" subtitle.
//
// The NSE is now the single source of iOS banners. This type is retained as
// an empty stub so the existing project file reference continues to compile;
// it can be deleted from the Xcode target whenever the project file is next
// regenerated.

import Foundation
import DoomCoderCore

@MainActor
enum LocalNotificationPoster {
    /// No-op. Kept for source compatibility; the NSE is now the only
    /// iOS notification path.
    static func post(_ r: NotificationLogRecord) {}
}
