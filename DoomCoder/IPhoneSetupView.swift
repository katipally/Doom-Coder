import SwiftUI
import AppKit

// MARK: - IPhoneSetupView
//
// Settings tab that walks the user through wiring one or more iPhone channels.
// Each channel has its own card with plain-English setup copy, a live "Ready"
// badge, a Test button, and a recent delivery log at the bottom so the user
// can see — at a glance — whether their phone is actually hearing from us.

struct IPhoneSetupView: View {

    @Bindable var relay: IPhoneRelay

    @State private var banner: Banner?

    struct Banner: Identifiable {
        let id = UUID()
        let kind: Kind
        let message: String
        enum Kind { case success, info, error }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let banner { bannerView(banner) }
                reminderCard
                imessageCard
                ntfyCard
                deliveryLogCard
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 600)
    }

    // MARK: - Header / footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iPhone notifications")
                .font(.title2).bold()
            Text("Any combination of these channels can fire at the same time. Turn on at least one so attention-grabbing events (wait for input, error, done) reach you while you're away from your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !relay.anyChannelEnabled {
                Label("No channels enabled — iPhone won't be notified yet.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Privacy")
                .font(.headline)
            Text("Reminders sync through your iCloud account; nothing leaves Apple. iMessage sends to a handle you supply. ntfy is optional and uses an unguessable topic you create — only someone with the exact topic URL can subscribe. DoomCoder never relays events to its own servers; there aren't any.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: - Cards

    private var reminderCard: some View {
        channelCard(
            icon: "checklist",
            title: "iCloud Reminders",
            summary: "Creates a completed reminder in your default list. It shows up on every iPhone signed into the same Apple ID, usually within seconds. No permission beyond Reminders access.",
            ready: relay.reminder.isReady,
            enabled: Binding(
                get: { relay.reminder.isEnabled },
                set: { relay.reminder.isEnabled = $0 }
            ),
            testAction: { relay.sendTest(channel: "Reminder") },
            permissionAction: {
                Task {
                    let ok = await relay.reminder.requestAccess()
                    banner = ok
                        ? Banner(kind: .success, message: "Reminders access granted.")
                        : Banner(kind: .error, message: "Reminders access denied. Open System Settings → Privacy & Security → Reminders to allow DoomCoder.")
                }
            },
            permissionButtonTitle: "Grant Reminders Access",
            needsPermission: !relay.reminder.isReady,
            body: { EmptyView() }
        )
    }

    private var imessageCard: some View {
        channelCard(
            icon: "message.fill",
            title: "iMessage to yourself",
            summary: "Sends an iMessage to the phone number or iCloud email you specify. The first time you hit Test, macOS will ask for permission to control Messages — approve it to finish setup.",
            ready: relay.imessage.isReady,
            enabled: Binding(
                get: { relay.imessage.isEnabled },
                set: { relay.imessage.isEnabled = $0 }
            ),
            testAction: { relay.sendTest(channel: "iMessage") },
            permissionAction: nil,
            permissionButtonTitle: nil,
            needsPermission: false,
            body: {
                TextField("+1 415 555 0199 or you@icloud.com",
                          text: Binding(
                            get: { relay.imessage.handle },
                            set: { relay.imessage.handle = $0 }
                          ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
            }
        )
    }

    private var ntfyCard: some View {
        channelCard(
            icon: "bell.badge.fill",
            title: "ntfy.sh push",
            summary: "Free, open-source push to the ntfy iOS app. We generate a random, unguessable topic for you — on your iPhone, install ntfy from the App Store, open the QR code below, and you're done.",
            ready: relay.ntfy.isReady,
            enabled: Binding(
                get: { relay.ntfy.isEnabled },
                set: { relay.ntfy.isEnabled = $0 }
            ),
            testAction: { relay.sendTest(channel: "ntfy") },
            permissionAction: { relay.ntfy.generateTopicIfNeeded() },
            permissionButtonTitle: relay.ntfy.isReady ? "Regenerate Topic" : "Generate Topic",
            needsPermission: false,
            body: {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("topic",
                              text: Binding(
                                get: { relay.ntfy.topic },
                                set: { relay.ntfy.topic = $0 }
                              ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))

                    if let url = relay.ntfy.subscriptionURL {
                        HStack(spacing: 8) {
                            Text(url.absoluteString)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                banner = Banner(kind: .info, message: "Subscription URL copied.")
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "safari")
                            }
                            .buttonStyle(.borderless)
                            .help("Open in browser to preview")
                        }
                    }
                }
            }
        )
    }

    private var deliveryLogCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent deliveries").font(.headline)
                    Spacer()
                    if !relay.deliveryLog.isEmpty {
                        Text("\(relay.deliveryLog.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if relay.deliveryLog.isEmpty {
                    Text("No deliveries yet. Enable a channel above and tap Test.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(relay.deliveryLog.prefix(8)) { d in
                        HStack(spacing: 8) {
                            Image(systemName: d.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(d.success ? .green : .red)
                            Text(d.formattedTimestamp)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(d.channel).font(.caption).bold()
                            Text("—").foregroundStyle(.secondary).font(.caption)
                            Text(d.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - Shared card template

    @ViewBuilder
    private func channelCard<Extra: View>(
        icon: String,
        title: String,
        summary: String,
        ready: Bool,
        enabled: Binding<Bool>,
        testAction: @escaping () -> Void,
        permissionAction: (() -> Void)?,
        permissionButtonTitle: String?,
        needsPermission: Bool,
        @ViewBuilder body: () -> Extra
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon).font(.title3)
                    Text(title).font(.headline)
                    Spacer()
                    Toggle("", isOn: enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                body()

                HStack(spacing: 8) {
                    if let permissionAction, let permissionButtonTitle {
                        Button(permissionButtonTitle, action: permissionAction)
                    }
                    Button {
                        testAction()
                    } label: {
                        Label("Send Test", systemImage: "paperplane")
                    }
                    .disabled(!enabled.wrappedValue)
                    Spacer()
                    statusDot(ready: ready, enabled: enabled.wrappedValue, needsPermission: needsPermission)
                }
                .font(.callout)
            }
            .padding(6)
        }
    }

    private func statusDot(ready: Bool, enabled: Bool, needsPermission: Bool) -> some View {
        let (label, color): (String, Color) = {
            if !enabled                  { return ("Off",       .secondary) }
            if needsPermission && !ready { return ("Needs permission", .orange) }
            if !ready                    { return ("Not configured",   .orange) }
            return ("Ready", .green)
        }()
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).bold().foregroundStyle(color)
        }
    }

    private func bannerView(_ banner: Banner) -> some View {
        let (icon, color): (String, Color) = {
            switch banner.kind {
            case .success: return ("checkmark.circle.fill", .green)
            case .info:    return ("info.circle.fill",      .accentColor)
            case .error:   return ("exclamationmark.triangle.fill", .red)
            }
        }()
        return HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(banner.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { self.banner = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
