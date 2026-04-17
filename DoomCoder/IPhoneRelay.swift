import Foundation
import AppKit
import Observation

// MARK: - IPhoneRelay
//
// Fans out attention-grabbing agent events (wait / error / done) to a single
// selected iPhone delivery channel. v1.2 removes the Calendar channel (iCloud
// alarm propagation was never reliable enough for this use-case in practice)
// and introduces a "selected channel" model: the user picks which channel
// delivers events from a dropdown of channels they've configured. Only the
// active channel fires — no fan-out, no priority stacking, no surprises.
//
// Channels today:
//   • NtfyChannel — HTTPS POST to ntfy.sh topic; user subscribes from the
//                   ntfy iOS app. Works cross-platform.
//
// Adding a channel later is a two-step mechanical extension:
//   1. Implement `IPhoneChannel` + persist `isReady` through UserDefaults.
//   2. Append to `allChannels`. It shows up in the dropdown automatically
//      once `isReady` flips true.

@MainActor
@Observable
final class IPhoneRelay {

    // MARK: Keys
    enum Keys {
        static let selectedChannelID = "dc.iphone.selectedChannel"
        static let ntfyTopic         = "dc.iphone.ntfy.topic"

        // Legacy keys — cleared by LegacyDefaults.migrate, referenced nowhere
        // else. Kept here only as a written record of the old surface.
        static let legacyCalendarEnabled = "dc.iphone.calendar.enabled"
        static let legacyNtfyEnabled     = "dc.iphone.ntfy.enabled"
        static let legacyReminderEnabled = "dc.iphone.reminder.enabled"
        static let legacyIMessageEnabled = "dc.iphone.imessage.enabled"
        static let legacyIMessageHandle  = "dc.iphone.imessage.handle"
        static let legacyFocusEnabled    = "dc.focus.filter.enabled"
    }

    // MARK: Channel descriptor

    struct ChannelInfo: Identifiable, Hashable, Sendable {
        let id: String
        let displayName: String
        let icon: String
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

    let ntfy = NtfyChannel()

    /// Static registry of every channel DoomCoder knows about, regardless of
    /// configuration state. Order here is the order shown in the picker.
    var allChannels: [(info: ChannelInfo, channel: any IPhoneChannel)] {
        [
            (ChannelInfo(id: "ntfy", displayName: "ntfy.sh", icon: "bell.badge.fill"), ntfy)
        ]
    }

    /// Only channels the user has configured enough to be *usable*
    /// (`isReady == true`). This drives the picker menu.
    var availableChannels: [ChannelInfo] {
        allChannels.filter { $0.channel.isReady }.map { $0.info }
    }

    /// Persisted id of the picked delivery method. Empty means "auto-pick the
    /// first ready channel" (good default on first launch).
    var selectedChannelID: String {
        get { UserDefaults.standard.string(forKey: Keys.selectedChannelID) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.selectedChannelID) }
    }

    /// The concrete channel `fire()` will actually deliver through. Resolves
    /// `selectedChannelID` if it points at a still-ready channel; otherwise
    /// falls back to the first ready channel; otherwise nil (none configured).
    /// The special value `"__none__"` means the user explicitly paused
    /// delivery — returns nil.
    var activeChannel: (info: ChannelInfo, channel: any IPhoneChannel)? {
        if selectedChannelID == "__none__" { return nil }
        let ready = allChannels.filter { $0.channel.isReady }
        if !selectedChannelID.isEmpty,
           let match = ready.first(where: { $0.info.id == selectedChannelID }) {
            return match
        }
        return ready.first
    }

    var anyChannelReady: Bool { !availableChannels.isEmpty }

    // MARK: Dispatch

    func fire(event: AgentEvent, session: AgentSession) {
        guard event.status.isAttention else { return }
        // User explicitly paused delivery — drop silently, no log noise.
        if selectedChannelID == "__none__" { return }

        guard let active = activeChannel else {
            // Record the miss so the user can see *why* nothing reached their
            // phone — otherwise the log stays empty and looks broken.
            let title = "\(session.displayName) • \(event.status.displayName)"
            record(channel: "—", title: title,
                   result: .failure(reason: "No delivery channel configured. Open Agent Tracking → iPhone Channels and set one up."))
            return
        }

        let title = "\(session.displayName) • \(event.status.displayName)"
        let body  = event.message
            ?? "\(session.repoName.map { "\($0) • " } ?? "")\(session.elapsedText)"

        let channelName = active.info.displayName
        let ch = active.channel
        Task.detached { [weak self] in
            let r = await ch.deliver(title: title, body: body)
            await MainActor.run { [weak self] in
                self?.record(channel: channelName, title: title, result: r)
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

    /// Fires a test delivery. If `channelID` is nil, uses the active channel;
    /// otherwise targets the named channel even if it's not the active one
    /// (useful from the channel detail pane's "Send Test" button).
    func sendTest(channelID: String? = nil) {
        let target: (info: ChannelInfo, channel: any IPhoneChannel)?
        if let id = channelID {
            target = allChannels.first { $0.info.id == id }
        } else {
            target = activeChannel
        }

        let title = "DoomCoder test"
        let body = "If you see this on your iPhone, the \(target?.info.displayName ?? "selected") channel is wired up."

        guard let t = target else {
            record(channel: "—", title: title,
                   result: .failure(reason: "No channel to test. Configure one in iPhone Channels."))
            return
        }
        guard t.channel.isReady else {
            record(channel: t.info.displayName, title: title,
                   result: .failure(reason: "Channel not ready. Re-run its setup sheet."))
            return
        }

        let channelName = t.info.displayName
        let ch = t.channel
        Task.detached { [weak self] in
            let r = await ch.deliver(title: title, body: body)
            await MainActor.run { [weak self] in
                self?.record(channel: channelName, title: title, result: r)
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
    /// Whether this channel has enough configuration to be chosen from the
    /// picker. There is no separate "enabled" bit in v1.2 — the user picks
    /// one ready channel as the active method. A channel "opts out" of
    /// delivery by reporting `isReady == false`.
    var isReady: Bool { get }
    func deliver(title: String, body: String) async -> DeliveryResult
}

// MARK: - ntfy.sh channel
//
// Posts a push notification via ntfy.sh. The user picks a topic slug (we
// generate a random one by default) and subscribes to it from the ntfy iOS
// app. No account, no phone number — just a URL.

@Observable
final class NtfyChannel: IPhoneChannel, @unchecked Sendable {

    var topic: String {
        get { UserDefaults.standard.string(forKey: IPhoneRelay.Keys.ntfyTopic) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: IPhoneRelay.Keys.ntfyTopic) }
    }

    var isReady: Bool {
        !topic.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Seed a short, random, unguessable topic. 8 hex chars ≈ 32 bits of
    /// entropy — enough for a private non-indexed ntfy topic, short enough
    /// to type on a phone if share-sheet paths fail.
    func generateTopicIfNeeded() {
        if topic.trimmingCharacters(in: .whitespaces).isEmpty {
            let bytes = (0..<4).map { _ in UInt8.random(in: 0...255) }
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            topic = "dc-\(hex)"
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
        let topic = self.topic.trimmingCharacters(in: .whitespaces)
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
