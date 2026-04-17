import Foundation
import EventKit
import AppKit
import Observation

// MARK: - IPhoneRelay
//
// Fans out attention-grabbing agent events (wait / error / done) to iPhone
// delivery channels. v1.1.0 removes Reminders + iMessage (both proved unreliable
// on real devices: Reminders were silently routed to Recently-Deleted, and
// iMessage-to-self is blocked by the iMessage service itself) and replaces
// them with a **Calendar event + short-offset alarm** on a dedicated iCloud
// "DoomCoder" calendar. Calendar alarms fire a genuine push notification on
// every Apple device signed into the same iCloud account — that's the only
// channel Apple guarantees for "wake up the user on their phone from a Mac".
//
// Surviving channels for v1.1.0:
//   • CalendarChannel — EKEvent on dedicated iCloud calendar with 0s alarm.
//   • NtfyChannel     — HTTPS POST to ntfy.sh topic; works cross-platform.

@MainActor
@Observable
final class IPhoneRelay {

    // MARK: Keys
    enum Keys {
        static let calendarEnabled = "dc.iphone.calendar.enabled"
        static let ntfyEnabled     = "dc.iphone.ntfy.enabled"
        static let ntfyTopic       = "dc.iphone.ntfy.topic"

        // Legacy keys (kept only for LegacyDefaults.migrate to read/clear).
        static let legacyReminderEnabled = "dc.iphone.reminder.enabled"
        static let legacyIMessageEnabled = "dc.iphone.imessage.enabled"
        static let legacyIMessageHandle  = "dc.iphone.imessage.handle"
        static let legacyFocusEnabled    = "dc.focus.filter.enabled"
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

    let calendar = CalendarChannel()
    let ntfy     = NtfyChannel()

    var enabledChannelCount: Int {
        [calendar.isEnabled, ntfy.isEnabled].filter { $0 }.count
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
        // Best-effort housekeeping before new delivery: remove old DoomCoder
        // calendar events so the user's calendar doesn't accumulate cruft.
        await calendar.cleanupOldEvents()

        let snapshots: [(String, any IPhoneChannel)] = [
            ("Calendar", calendar),
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
                ("Calendar", self.calendar),
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

// MARK: - Calendar channel (EventKit)
//
// Creates a short event on a dedicated "DoomCoder" calendar on the user's
// iCloud account (falls back to local). The event starts a few seconds from
// now and has an `EKAlarm` at zero offset so an alert fires immediately on
// every Apple device signed into the same iCloud account. This is the most
// reliable cross-device push path available to a Mac-only app in April 2026.
//
// We keep the alarm offset very short (default 3 s) so the user gets woken
// up promptly — but non-zero so iCloud has time to sync the event to the
// phone before the alarm triggers there (zero-offset on a just-created event
// sometimes loses the phone race entirely).

@Observable
final class CalendarChannel: IPhoneChannel, @unchecked Sendable {
    private let store = EKEventStore()

    /// Title of the dedicated calendar we create. Keep stable — we look it up
    /// by name on each launch.
    static let dedicatedCalendarName = "DoomCoder"

    /// Tag we stamp into event notes so we can recognize + clean up our own
    /// events without touching anything the user created.
    static let sentinel = "[dc-alarm/v1]"

    /// How far in the future to schedule the alarm. Short enough to feel
    /// instant, long enough for the event to propagate through iCloud to the
    /// iPhone before its alarm fires locally.
    var alarmOffsetSeconds: TimeInterval = 3

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: IPhoneRelay.Keys.calendarEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: IPhoneRelay.Keys.calendarEnabled) }
    }

    var isReady: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAccess() async -> Bool {
        do { return try await store.requestFullAccessToEvents() }
        catch { return false }
    }

    // MARK: Calendar resolution

    /// Returns (or creates) the dedicated DoomCoder calendar. Prefers an
    /// iCloud-backed calDAV source so events sync to iPhone; falls back to
    /// local if iCloud isn't available (rare but possible).
    private func resolveCalendar() -> EKCalendar? {
        let name = Self.dedicatedCalendarName
        if let existing = store.calendars(for: .event).first(where: { $0.title == name }) {
            return existing
        }

        // Pick a source: iCloud (calDAV) first, then local.
        let sources = store.sources
        let source = sources.first(where: { $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("icloud") })
            ?? sources.first(where: { $0.sourceType == .calDAV })
            ?? sources.first(where: { $0.sourceType == .local })

        guard let source else { return nil }

        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = name
        cal.source = source
        cal.cgColor = NSColor.systemOrange.cgColor

        do {
            try store.saveCalendar(cal, commit: true)
            return cal
        } catch {
            // Couldn't write to iCloud source (some corporate / restricted
            // setups). Retry against local.
            if source.sourceType != .local,
               let local = sources.first(where: { $0.sourceType == .local }) {
                cal.source = local
                if (try? store.saveCalendar(cal, commit: true)) != nil {
                    return cal
                }
            }
            return nil
        }
    }

    // MARK: Deliver

    func deliver(title: String, body: String) async -> DeliveryResult {
        guard self.isEnabled else { return .failure(reason: "Disabled") }
        guard self.isReady else {
            return .failure(reason: "Calendar access not granted. Open Agent Tracking → Calendar → Request Permission.")
        }
        guard let cal = resolveCalendar() else {
            return .failure(reason: "Couldn't create DoomCoder calendar. Check Settings → Apple ID → iCloud → Calendars.")
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = "\(body)\n\n\(Self.sentinel)"
        event.calendar = cal

        let start = Date.now.addingTimeInterval(alarmOffsetSeconds)
        let end   = start.addingTimeInterval(60)
        event.startDate = start
        event.endDate   = end

        // Relative offset 0 = fire at startDate. The startDate itself is
        // already in the near future, so the alarm lands shortly after sync.
        event.addAlarm(EKAlarm(relativeOffset: 0))

        do {
            try store.save(event, span: .thisEvent, commit: true)
            return .success(detail: "Alarm set on \(cal.title) in \(Int(alarmOffsetSeconds))s")
        } catch {
            return .failure(reason: error.localizedDescription)
        }
    }

    // MARK: Cleanup
    //
    // Sweeps DoomCoder-tagged events whose end-date is in the past and removes
    // them so the user's calendar doesn't accumulate a huge stripe of orange
    // ticks. Best-effort: silent on failure.

    func cleanupOldEvents(olderThan age: TimeInterval = 60 * 30) async {
        guard self.isReady, let cal = resolveCalendar() else { return }
        let cutoff = Date.now.addingTimeInterval(-age)
        // Fetch a generous window: last 30 days up to cutoff.
        let windowStart = Date.now.addingTimeInterval(-60 * 60 * 24 * 30)
        let pred = store.predicateForEvents(withStart: windowStart, end: cutoff, calendars: [cal])
        let events = store.events(matching: pred)
        for e in events where (e.notes ?? "").contains(Self.sentinel) {
            try? store.remove(e, span: .thisEvent, commit: false)
        }
        try? store.commit()
    }

    // MARK: iCloud round-trip test
    //
    // Writes a probe event, polls a fresh EKEventStore until it sees the
    // event, then deletes it. Proves Mac → iCloud propagation is wired up
    // (from which iPhone propagation follows).

    enum RoundTripError: Error, LocalizedError {
        case notAuthorized
        case noCalendar
        case writeFailed(String)
        case timeout(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:      return "Calendar access not granted. Allow it in Channel Setup → Calendar first."
            case .noCalendar:         return "Couldn't create DoomCoder calendar. Check Settings → Apple ID → iCloud → Calendars."
            case .writeFailed(let m): return "Couldn't save test event: \(m)"
            case .timeout(let s):     return "Event didn't propagate through iCloud within \(Int(s))s. Check Settings → Apple ID → iCloud → Calendars is on."
            }
        }
    }

    func runICloudRoundTripTest(timeout: TimeInterval = 15) async -> Result<TimeInterval, RoundTripError> {
        guard self.isReady else { return .failure(.notAuthorized) }
        guard let cal = resolveCalendar() else { return .failure(.noCalendar) }

        let marker = UUID().uuidString
        let title  = "DC-ROUNDTRIP-\(marker)"
        let start  = Date.now.addingTimeInterval(60 * 60)  // 1h out, no alarm
        let end    = start.addingTimeInterval(60)
        let writeStart = Date.now

        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = "DoomCoder iCloud round-trip probe. Safe to delete."
        event.calendar = cal
        event.startDate = start
        event.endDate = end
        // No alarm — this is a sync probe, not a real delivery.

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }

        let probe = EKEventStore()
        let deadline = Date.now.addingTimeInterval(timeout)
        var matched = false

        while Date.now < deadline && !matched {
            try? await Task.sleep(for: .milliseconds(500))
            let pred = probe.predicateForEvents(
                withStart: start.addingTimeInterval(-60),
                end: start.addingTimeInterval(120),
                calendars: nil
            )
            let hits = probe.events(matching: pred)
            matched = hits.contains { $0.title == title }
        }

        try? store.remove(event, span: .thisEvent, commit: true)

        if matched {
            return .success(Date.now.timeIntervalSince(writeStart))
        }
        return .failure(.timeout(timeout))
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

    /// URL the ntfy iOS app cares about for subscription. Clicking this URL
    /// from any app on iPhone opens the ntfy app directly (if installed) via
    /// its registered `ntfy://` scheme.
    var deepLinkURL: URL? {
        guard isReady else { return nil }
        return URL(string: "ntfy://subscribe?topic=\(topic)&server=ntfy.sh")
    }

    /// HTTPS URL — what you'd open in a browser to see the topic feed. Useful
    /// as a QR-code fallback for anyone who can't / won't install the app.
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
