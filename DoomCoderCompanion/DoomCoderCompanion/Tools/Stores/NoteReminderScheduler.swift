// NoteReminderScheduler.swift — DoomCoder Companion (Tools)
// Schedules/cancels a single local notification per note reminder. Notification
// permission is requested LAZILY — only the first time a user actually sets a
// reminder — so the app never prompts at launch (App Store 4.2.3 / HIG safe).

import Foundation
import UserNotifications
import DoomCoderCore

enum NoteReminderScheduler {

    enum ScheduleResult: Equatable {
        case scheduled
        case permissionDenied
        case dateInPast
        case failed(String)
    }

    /// Requests authorization if needed, then schedules a one-shot local
    /// notification firing at `reminder.date`. Returns the outcome so the UI can
    /// guide the user (e.g. to Settings) when permission is denied.
    static func schedule(reminder: NoteReminder, noteTitle: String) async -> ScheduleResult {
        guard reminder.date > Date().addingTimeInterval(5) else { return .dateInPast }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return .permissionDenied }
        case .denied:
            return .permissionDenied
        default:
            break
        }

        // Replace any prior request with the same id (deterministic id per reminder).
        center.removePendingNotificationRequests(withIdentifiers: [reminder.notificationID])

        let content = UNMutableNotificationContent()
        content.title = "Note reminder"
        content.body = noteTitle.isEmpty ? "You set a reminder on a note." : noteTitle
        content.sound = .default

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: reminder.date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: reminder.notificationID, content: content, trigger: trigger)

        do {
            try await center.add(request)
            return .scheduled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func cancel(notificationID: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationID])
    }
}
