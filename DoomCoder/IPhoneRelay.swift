import Foundation
import EventKit
import AppKit
import Observation

// MARK: - IPhoneRelay
//
// Fans out attention-grabbing agent events (wait / error / done) to one or more
// iPhone-visible channels in parallel. Every channel is independent — a
// failure in one doesn't stop the others, and every delivery attempt is
// recorded in `deliveryLog` so the user can confirm what actually reached
// their phone.
//
// Design goals:
//   1. Triple-redundant: if iCloud is slow, iMessage still works; if Messages
//      permission is denied, ntfy still works.
//   2. Zero network metadata leaked: default config uses Apple's own sync
//      paths. ntfy is opt-in.
//   3. Stateless channels: each channel re-reads UserDefaults on every
//      `deliver`, so the Settings window can flip a switch and the next event
//      reflects it without any observer plumbing.

@MainActor
@Observable
final class IPhoneRelay {

    // MARK: Keys
    enum Keys {
        static let reminderEnabled = "dc.iphone.reminder.enabled"
        static let imessageEnabled = "dc.iphone.imessage.enabled"
        static let imessageHandle  = "dc.iphone.imessage.handle"
        static let ntfyEnabled     = "dc.iphone.ntfy.enabled"
        static let ntfyTopic       = "dc.iphone.ntfy.topic"
    }

    // MARK: State

    struct Delivery: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let channel: String
        let title: String
        let success: Bool
        let detail: String
    }

    private(set) var deliveryLog: [Delivery] = []
    private let maxLog = 50

    func clearDeliveryLog() { deliveryLog.removeAll() }

    // MARK: Channels

    let reminder = ReminderChannel()
    let imessage = IMessageChannel()
    let ntfy     = NtfyChannel()

    var enabledChannelCount: Int {
        [reminder.isEnabled, imessage.isEnabled, ntfy.isEnabled].filter { $0 }.count
    }

    var anyChannelEnabled: Bool { enabledChannelCount > 0 }

    // MARK: Dispatch

    func fire(event: AgentEvent, session: AgentSession) {
        guard event.status.isAttention else { return }
        let title = "\(session.displayName) • \(event.status.displayName)"
        let body  = event.message
            ?? "\(session.repoName.map { "\($0) • " } ?? "")\(session.elapsedText)"

        Task.detached { [weak self] in
            await self?.runAllChannels(title: title, body: body)
        }
    }

    private func runAllChannels(title: String, body: String) async {
        // Best-effort housekeeping before we drop a new reminder on the user's
        // phone: auto-complete any DoomCoder-tagged reminders older than an
        // hour so the list doesn't grow unbounded.
        await reminder.cleanupDeliveredReminders()
        let snapshots: [(String, any IPhoneChannel)] = [
            ("Reminder", reminder),
            ("iMessage", imessage),
            ("ntfy",     ntfy)
        ]
        await withTaskGroup(of: (String, DeliveryResult).self) { group in
            for (name, ch) in snapshots where ch.isEnabled {
                group.addTask { [ch] in
                    let r = await ch.deliver(title: title, body: body)
                    return (name, r)
                }
            }
            for await (name, r) in group {
                await MainActor.run { [weak self] in
                    self?.record(channel: name, title: title, result: r)
                }
            }
        }
    }

    private func record(channel: String, title: String, result: DeliveryResult) {
        let delivery: Delivery
        switch result {
        case .success(let detail):
            delivery = Delivery(timestamp: .now, channel: channel, title: title,
                                success: true, detail: detail)
        case .failure(let reason):
            delivery = Delivery(timestamp: .now, channel: channel, title: title,
                                success: false, detail: reason)
        }
        deliveryLog.insert(delivery, at: 0)
        if deliveryLog.count > maxLog {
            deliveryLog = Array(deliveryLog.prefix(maxLog))
        }
    }

    // MARK: Synthetic test

    /// Fires a single-channel or all-channels test delivery and records the
    /// result exactly like a real event would.
    func sendTest(channel only: String? = nil) {
        let title = "DoomCoder test"
        let body = "If you see this on your iPhone, the \(only ?? "iPhone") channel is wired up."

        Task.detached { [weak self] in
            guard let self else { return }
            let chs: [(String, any IPhoneChannel)] = [
                ("Reminder", self.reminder),
                ("iMessage", self.imessage),
                ("ntfy",     self.ntfy)
            ]
            for (name, ch) in chs where (only == nil || only == name) {
                guard ch.isEnabled else {
                    await MainActor.run { [weak self] in
                        self?.record(channel: name, title: title,
                                     result: .failure(reason: "Disabled"))
                    }
                    continue
                }
                let r = await ch.deliver(title: title, body: body)
                await MainActor.run { [weak self] in
                    self?.record(channel: name, title: title, result: r)
                }
            }
        }
    }
}

// MARK: - Channel contract

enum DeliveryResult: Sendable {
    case success(detail: String)
    case failure(reason: String)
}

protocol IPhoneChannel: Sendable {
    var isEnabled: Bool { get }
    var isReady:   Bool { get }
    func deliver(title: String, body: String) async -> DeliveryResult
}

// MARK: - Reminder channel (EventKit)
//
// Writes an **uncompleted** reminder with an immediate alarm into the user's
// default Reminders list. Because Reminders sync via iCloud, the item shows
// up — and *notifies* — on any iPhone signed into the same Apple ID within
// seconds.
//
// IMPORTANT: Earlier iterations used `isCompleted = true`, which *did* sync
// but was silently filed under "Completed" on iPhone with no notification.
// That's why v1.0.0 users reported "the iPhone side is broken" — it wasn't
// broken, just silent. Real deliveries now use an alarm at `Date.now` so the
// iPhone fires a banner / lock-screen notification immediately. We tag every
// DoomCoder reminder with a sentinel note prefix so a background cleanup
// pass can auto-complete stale ones and keep the user's list tidy.

@Observable
final class ReminderChannel: IPhoneChannel, @unchecked Sendable {
    private let store = EKEventStore()

    // Sentinel prefix embedded in the reminder notes so cleanup can recognize
    // reminders we wrote without affecting the user's own entries.
    static let sentinel = "[dc-reminder/v1]"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: IPhoneRelay.Keys.reminderEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: IPhoneRelay.Keys.reminderEnabled) }
    }

    var isReady: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    func requestAccess() async -> Bool {
        do { return try await store.requestFullAccessToReminders() }
        catch { return false }
    }

    func deliver(title: String, body: String) async -> DeliveryResult {
        guard self.isEnabled else { return .failure(reason: "Disabled") }
        guard self.isReady else {
            return .failure(reason: "Reminders access not granted. Open Agent Tracking → Reminders → Request Permission.")
        }
        guard let list = self.store.defaultCalendarForNewReminders() else {
            return .failure(reason: "No default Reminders list — open Reminders.app once to create one.")
        }

        let reminder = EKReminder(eventStore: self.store)
        reminder.title = title
        // Tag notes with a sentinel on its own line so cleanup can match it
        // precisely without affecting lines the user might edit.
        reminder.notes = "\(body)\n\n\(Self.sentinel)"
        reminder.calendar = list
        reminder.isCompleted = false
        reminder.priority = 1  // High priority — iPhone surfaces it faster.

        // An uncompleted reminder only fires a notification on iPhone when it
        // has both a `dueDateComponents` (so Reminders.app treats it as a
        // scheduled task) and an `EKAlarm` (the actual trigger). We set both
        // to "now" so the phone lights up within a few seconds of iCloud
        // propagation.
        let due = Date.now
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .timeZone],
            from: due
        )
        reminder.addAlarm(EKAlarm(absoluteDate: due))

        do {
            try self.store.save(reminder, commit: true)
            return .success(detail: "Notified via \(list.title)")
        } catch {
            return .failure(reason: error.localizedDescription)
        }
    }

    // MARK: - Cleanup
    //
    // Uncompleted reminders we wrote will stick around on the user's Mac +
    // iPhone forever otherwise. Called opportunistically (app launch, before
    // each new delivery) to mark DoomCoder reminders older than `age` as
    // completed, which moves them into the Completed section on iPhone and
    // stops them from re-firing. Best-effort: any failure is ignored.

    func cleanupDeliveredReminders(olderThan age: TimeInterval = 60 * 60) async {
        guard self.isReady else { return }
        guard let list = self.store.defaultCalendarForNewReminders() else { return }
        let cutoff = Date.now.addingTimeInterval(-age)
        let store = self.store
        let pred = store.predicateForReminders(in: [list])

        // Pull titles/ids out on EventKit's thread so no non-Sendable EKReminder
        // crosses a concurrency boundary.
        let matchIds: [String] = await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            store.fetchReminders(matching: pred) { items in
                let ids = (items ?? [])
                    .filter {
                        ($0.notes ?? "").contains(Self.sentinel) &&
                        !$0.isCompleted &&
                        ($0.creationDate ?? .distantFuture) < cutoff
                    }
                    .map { $0.calendarItemIdentifier }
                cont.resume(returning: ids)
            }
        }

        for id in matchIds {
            if let reminder = store.calendarItems(withExternalIdentifier: id).first as? EKReminder
                ?? (store.calendarItem(withIdentifier: id) as? EKReminder)
            {
                reminder.isCompleted = true
                reminder.completionDate = .now
                try? store.save(reminder, commit: false)
            }
        }
        try? store.commit()
    }

    // MARK: - iCloud round-trip test
    //
    // Writes a unique marker reminder, then polls a *fresh* EKEventStore (so
    // we read through iCloud, not the local cache) until the marker shows up
    // or `timeout` elapses. On success we delete the marker and return the
    // observed round-trip latency. This proves the full write → iCloud →
    // iPhone propagation loop is wired up.
    enum RoundTripError: Error, LocalizedError {
        case notAuthorized
        case noDefaultList
        case writeFailed(String)
        case timeout(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:       return "Reminders access not granted. Allow it in Channel Setup → Reminders first."
            case .noDefaultList:       return "No default Reminders list. Open Reminders.app once to create one."
            case .writeFailed(let m):  return "Couldn't save test reminder: \(m)"
            case .timeout(let s):      return "Reminder didn't propagate through iCloud within \(Int(s))s. Check Settings → Apple ID → iCloud → Reminders is on."
            }
        }
    }

    func runICloudRoundTripTest(timeout: TimeInterval = 15) async -> Result<TimeInterval, RoundTripError> {
        guard self.isReady else { return .failure(.notAuthorized) }
        guard let list = self.store.defaultCalendarForNewReminders() else {
            return .failure(.noDefaultList)
        }

        let marker = UUID().uuidString
        let title  = "DC-ROUNDTRIP-\(marker)"
        let writeStart = Date.now

        let reminder = EKReminder(eventStore: self.store)
        reminder.title = title
        // Intentionally omits the sentinel — this is a sync probe, not a
        // user-visible delivery, so cleanup should ignore it. We mark it
        // completed immediately so iPhone Reminders won't notify.
        reminder.notes = "DoomCoder iCloud round-trip probe. Safe to delete."
        reminder.calendar = list
        reminder.isCompleted = true
        reminder.completionDate = .now

        do {
            try self.store.save(reminder, commit: true)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }

        // Poll with a fresh store. EventKit caches aggressively on the
        // handle that wrote the item, so reading back with the SAME store
        // is a lie — it'd succeed instantly regardless of iCloud. A new
        // store reloads from the local CoreData mirror which is kept in
        // sync with iCloud, so this is a true propagation probe on the
        // device the user is sitting at.
        let probe = EKEventStore()
        let deadline = Date.now.addingTimeInterval(timeout)
        var matched = false

        while Date.now < deadline && !matched {
            try? await Task.sleep(for: .milliseconds(500))
            let pred = probe.predicateForReminders(in: [list])
            // Compare titles inside the EventKit callback so the only value
            // that crosses the concurrency boundary is a Bool (Sendable).
            // EKReminder itself isn't Sendable under Swift 6 strict checking.
            matched = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                probe.fetchReminders(matching: pred) { items in
                    let hit = (items ?? []).contains { $0.title == title }
                    cont.resume(returning: hit)
                }
            }
        }

        if matched {
            let latency = Date.now.timeIntervalSince(writeStart)
            try? self.store.remove(reminder, commit: true)
            return .success(latency)
        }

        // Clean up the marker we wrote so we don't pollute the user's list.
        try? self.store.remove(reminder, commit: true)
        return .failure(.timeout(timeout))
    }
}

// MARK: - iMessage channel (AppleScript → Messages.app)
//
// Sends an iMessage to a handle the user configures (their own phone number
// or iCloud email). This is the fastest end-to-end path to an iPhone — push
// typically lands within seconds — but requires Automation permission for
// Messages.app.

@Observable
final class IMessageChannel: IPhoneChannel, @unchecked Sendable {

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: IPhoneRelay.Keys.imessageEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: IPhoneRelay.Keys.imessageEnabled) }
    }

    var handle: String {
        get { UserDefaults.standard.string(forKey: IPhoneRelay.Keys.imessageHandle) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: IPhoneRelay.Keys.imessageHandle) }
    }

    /// Ready once a non-empty handle is saved. Automation permission is
    /// requested lazily on first delivery; macOS shows the permission prompt
    /// automatically the first time we dispatch an Apple Event.
    var isReady: Bool {
        !Self.normalizeHandle(handle).isEmpty
    }

    /// Normalizes a user-entered handle for AppleScript lookup:
    ///   • strips whitespace, dashes, parentheses, spaces, dots
    ///   • if the result is all-digits (optionally with a leading +), ensures
    ///     a leading + (Messages requires E.164 form for phone numbers)
    ///   • leaves email addresses untouched aside from trimming
    static func normalizeHandle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") { return trimmed }
        let digits = trimmed.unicodeScalars
            .filter { CharacterSet(charactersIn: "0123456789+").contains($0) }
            .map { Character($0) }
        let compact = String(digits)
        if compact.isEmpty { return "" }
        if compact.hasPrefix("+") { return compact }
        return "+\(compact)"
    }

    /// Triggers a harmless Apple Event so macOS surfaces its Automation
    /// permission prompt for Messages.app. Called from the Channel Setup
    /// Sheet before the real test so the user sees the system prompt in a
    /// context where they expect it. Returns whether permission was granted.
    nonisolated func primeAutomationPermission() async -> DeliveryResult {
        let script = """
        tell application "Messages"
            return (count of services)
        end tell
        """
        return await Task.detached { () -> DeliveryResult in
            var error: NSDictionary?
            _ = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error { return Self.decodeAppleScriptError(error) }
            return .success(detail: "Automation permission granted")
        }.value
    }

    nonisolated func deliver(title: String, body: String) async -> DeliveryResult {
        let isEnabled = self.isEnabled
        let handle    = Self.normalizeHandle(self.handle)
        guard isEnabled else { return .failure(reason: "Disabled") }
        guard !handle.isEmpty else { return .failure(reason: "No handle configured") }

        let message = Self.escapeForAppleScript("\(title)\n\(body)")
        let escapedHandle = Self.escapeForAppleScript(handle)

        // Primary form: `buddy X of targetService`. This is the canonical
        // AppleScript dialect for Messages.app and resolves for any handle
        // iMessage has seen — including yourself, as long as you're signed
        // into iMessage on this Mac. If that fails we fall back to the
        // `participant` form in case buddy resolution is flaky on a given
        // macOS build.
        let primary = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(escapedHandle)" of targetService
            send "\(message)" to targetBuddy
        end tell
        """

        let fallback = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            send "\(message)" to participant "\(escapedHandle)" of targetService
        end tell
        """

        return await Task.detached { () -> DeliveryResult in
            var error: NSDictionary?
            _ = NSAppleScript(source: primary)?.executeAndReturnError(&error)
            if error == nil {
                return .success(detail: "Sent to \(handle)")
            }
            // Retry with the `participant` form.
            var fallbackError: NSDictionary?
            _ = NSAppleScript(source: fallback)?.executeAndReturnError(&fallbackError)
            if fallbackError == nil {
                return .success(detail: "Sent to \(handle)")
            }
            // Both forms failed: surface the most specific error we got.
            return Self.decodeAppleScriptError(fallbackError ?? error ?? [:])
        }.value
    }

    /// Turn a raw AppleScript error dictionary into a user-actionable
    /// DeliveryResult. macOS returns a small zoo of error numbers for
    /// Messages automation; the common ones:
    ///   -1743  errAEEventNotPermitted — Automation denied in System Settings
    ///   -1728  errAENoSuchObject      — buddy / participant not resolvable
    ///   -600   procNotFound           — Messages.app isn't running
    ///    -25   errOSASystemError      — generic
    static func decodeAppleScriptError(_ dict: NSDictionary) -> DeliveryResult {
        let code = (dict[NSAppleScript.errorNumber] as? Int) ?? 0
        let msg  = (dict[NSAppleScript.errorMessage] as? String) ?? "Unknown AppleScript error"
        switch code {
        case -1743:
            return .failure(reason: "Automation permission denied. Open System Settings → Privacy & Security → Automation → DoomCoder and enable Messages.")
        case -1728:
            return .failure(reason: "Messages couldn't find that handle. Make sure you've signed into iMessage with that number/email on this Mac (Messages → Settings → iMessage).")
        case -600:
            return .failure(reason: "Messages.app isn't running. Launch it once, sign in, then try again.")
        default:
            return .failure(reason: "\(msg) (code \(code))")
        }
    }

    /// Escape backslashes and double-quotes so a Swift string can be embedded
    /// safely into an AppleScript string literal.
    static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - ntfy.sh channel
//
// Posts a push notification via ntfy.sh. The user picks a topic slug (we
// generate a random one by default) and subscribes to it from the ntfy iOS
// app. No account, no phone number — just a URL.

@Observable
final class NtfyChannel: IPhoneChannel, @unchecked Sendable {

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: IPhoneRelay.Keys.ntfyEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: IPhoneRelay.Keys.ntfyEnabled) }
    }

    var topic: String {
        get { UserDefaults.standard.string(forKey: IPhoneRelay.Keys.ntfyTopic) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: IPhoneRelay.Keys.ntfyTopic) }
    }

    var isReady: Bool {
        !topic.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Seed a random, unguessable topic so the user can subscribe before they
    /// ever receive a message. 22 base32-ish chars.
    func generateTopicIfNeeded() {
        if topic.trimmingCharacters(in: .whitespaces).isEmpty {
            let bytes = (0..<14).map { _ in UInt8.random(in: 0...255) }
            let b32 = bytes.map { String(format: "%02x", $0) }.joined()
            topic = "doom-\(b32.prefix(22))"
        }
    }

    var subscriptionURL: URL? {
        guard isReady else { return nil }
        return URL(string: "https://ntfy.sh/\(topic)")
    }

    nonisolated func deliver(title: String, body: String) async -> DeliveryResult {
        let isEnabled = self.isEnabled
        let topic     = self.topic.trimmingCharacters(in: .whitespaces)
        guard isEnabled else { return .failure(reason: "Disabled") }
        guard !topic.isEmpty,
              let url = URL(string: "https://ntfy.sh/\(topic)") else {
            return .failure(reason: "No topic configured")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(title, forHTTPHeaderField: "Title")
        req.setValue("default", forHTTPHeaderField: "Priority")
        req.setValue("doomcoder,agent", forHTTPHeaderField: "Tags")
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 8

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return .success(detail: "ntfy.sh/\(topic)")
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return .failure(reason: "HTTP \(code)")
        } catch {
            return .failure(reason: error.localizedDescription)
        }
    }
}

// MARK: - Helpers

extension IPhoneRelay.Delivery {
    var formattedTimestamp: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: timestamp)
    }
}
