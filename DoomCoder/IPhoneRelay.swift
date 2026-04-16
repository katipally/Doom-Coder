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
// Writes a completed reminder into the user's default Reminders list. Because
// Reminders sync via iCloud, the item shows up on any iPhone signed into the
// same Apple ID within seconds. Using a "completed" reminder avoids polluting
// the user's actual task list while still showing up in Today/Notifications.

@Observable
final class ReminderChannel: IPhoneChannel, @unchecked Sendable {
    private let store = EKEventStore()

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: IPhoneRelay.Keys.reminderEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: IPhoneRelay.Keys.reminderEnabled) }
    }

    var isReady: Bool {
        if #available(macOS 14.0, *) {
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        }
        // Pre-14 fall-through: EKAuthorizationStatus.authorized exists there.
        return EKEventStore.authorizationStatus(for: .reminder).rawValue == 3
    }

    func requestAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            do { return try await store.requestFullAccessToReminders() }
            catch { return false }
        } else {
            return await withCheckedContinuation { cont in
                store.requestAccess(to: .reminder) { granted, _ in cont.resume(returning: granted) }
            }
        }
    }

    func deliver(title: String, body: String) async -> DeliveryResult {
        guard self.isEnabled else { return .failure(reason: "Disabled") }
        guard self.isReady else { return .failure(reason: "Reminders access not granted") }
        guard let list = self.store.defaultCalendarForNewReminders() else {
            return .failure(reason: "No default Reminders list")
        }
        let reminder = EKReminder(eventStore: self.store)
        reminder.title = title
        reminder.notes = body
        reminder.calendar = list
        reminder.isCompleted = true
        reminder.completionDate = .now
        do {
            try self.store.save(reminder, commit: true)
            return .success(detail: "Saved to \(list.title)")
        } catch {
            return .failure(reason: error.localizedDescription)
        }
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
        !handle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    nonisolated func deliver(title: String, body: String) async -> DeliveryResult {
        let isEnabled = self.isEnabled
        let handle    = self.handle.trimmingCharacters(in: .whitespaces)
        guard isEnabled else { return .failure(reason: "Disabled") }
        guard !handle.isEmpty else { return .failure(reason: "No handle configured") }

        let message = "\(title)\n\(body)"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedHandle = handle.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(escapedHandle)" of targetService
            send "\(message)" to targetBuddy
        end tell
        """

        return await Task.detached { () -> DeliveryResult in
            var error: NSDictionary?
            let appleScript = NSAppleScript(source: script)
            _ = appleScript?.executeAndReturnError(&error)
            if let error, let msg = error[NSAppleScript.errorMessage] as? String {
                return .failure(reason: msg)
            }
            return .success(detail: "Sent to \(handle)")
        }.value
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
