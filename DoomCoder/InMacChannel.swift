import Foundation
import AppKit
import Observation
import UserNotifications

// MARK: - InMacChannel
//
// v1.8.2 — local "attention" channel for people who work at their Mac and
// don't want to involve a phone push (ntfy) at all. On `deliver` we:
//
//   1. Post a `UNNotificationRequest` at `.timeSensitive` interruption level
//      so it punches through Focus/DND without needing the `.critical`
//      entitlement.
//   2. Loop an AppKit `NSSound` on a 1s timer for up to `durationSeconds`
//      seconds so the banner is actually noticeable while the Mac is mixed
//      in with real-life noise / headphones / meetings.
//   3. Stop immediately when the user clicks / dismisses the banner (that
//      path is handled by `NotificationManager`'s delegate, which calls
//      `InMacAlert.shared.stop()`).
//
// No entitlement, no network, no server. Honors system mute automatically
// because `NSSound` routes through the default output device respecting the
// master volume.

@MainActor
final class InMacAlert {
    static let shared = InMacAlert()
    private init() {}

    static let categoryID = "doomcoder.inmac"

    /// Persisted in UserDefaults. 5/7/10s presets. The channel is always
    /// "ready" — no config needed — so the picker sees it immediately.
    var durationSeconds: Int {
        get {
            let raw = UserDefaults.standard.integer(forKey: "dc.inmac.duration")
            return raw == 0 ? 7 : raw
        }
        set { UserDefaults.standard.set(newValue, forKey: "dc.inmac.duration") }
    }

    /// System sound name. "Funk" is distinctive enough to not blend with
    /// default UN banner sound but unobtrusive enough to not feel punishing
    /// during back-to-back agent turns.
    var soundName: String {
        get { UserDefaults.standard.string(forKey: "dc.inmac.sound") ?? "Funk" }
        set { UserDefaults.standard.set(newValue, forKey: "dc.inmac.sound") }
    }

    private var timer: Timer?
    private var remaining: Int = 0

    func fire(title: String, body: String) {
        // Post the banner.
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.interruptionLevel = .timeSensitive
        content.sound = nil // we own the audio so we can loop + stop it
        content.categoryIdentifier = Self.categoryID
        let id = "doomcoder.inmac.\(Int(Date().timeIntervalSince1970))"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }

        // Start looping sound.
        startLoopingSound()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSSound(named: soundName)?.stop()
    }

    private func startLoopingSound() {
        stop()
        remaining = max(1, durationSeconds)
        playOnce()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                self.remaining -= 1
                if self.remaining <= 0 {
                    self.stop()
                } else {
                    self.playOnce()
                }
            }
        }
    }

    private func playOnce() {
        // NSSound returns nil if the named sound is missing — fall back.
        let s = NSSound(named: soundName) ?? NSSound(named: "Funk")
        s?.stop()
        s?.play()
    }
}

// MARK: - InMacChannel

/// Adapter that makes InMacAlert speak the `IPhoneChannel` protocol so it
/// plugs into the existing `IPhoneRelay.activeChannel` pipeline without any
/// special-casing inside `fire()`.
final class InMacChannel: IPhoneChannel, @unchecked Sendable {
    /// In-Mac channel is always ready — there is literally nothing to
    /// configure beyond the one-time UN authorization (which is requested on
    /// first delivery attempt anyway via the shared NotificationManager).
    var isReady: Bool { true }

    nonisolated func deliver(title: String, body: String) async -> DeliveryResult {
        await MainActor.run {
            InMacAlert.shared.fire(title: title, body: body)
        }
        return .success(detail: "In-Mac alert fired")
    }
}
