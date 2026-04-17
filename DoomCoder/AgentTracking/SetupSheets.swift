import SwiftUI
import CoreImage.CIFilterBuiltins
import AppKit

// MARK: - SetupStep

enum SetupStep: Int, CaseIterable {
    case explain = 0, install, verify

    var title: String {
        switch self {
        case .explain: return "What this does"
        case .install: return "Install"
        case .verify:  return "Verify"
        }
    }
}

// MARK: - StepDots

private struct StepDots: View {
    let current: SetupStep
    var body: some View {
        HStack(spacing: 10) {
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                HStack(spacing: 6) {
                    Circle()
                        .fill(step.rawValue <= current.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 10, height: 10)
                    Text(step.title)
                        .font(.caption)
                        .foregroundStyle(step == current ? .primary : .secondary)
                }
                if step != SetupStep.allCases.last {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 1)
                        .frame(maxWidth: 24)
                }
            }
        }
    }
}

// MARK: - AgentSetupSheet

struct AgentSetupSheet: View {
    let agentId: String
    let onDone: () -> Void

    @State private var step: SetupStep = .explain
    @State private var installLog: String = ""
    @State private var installing = false
    @State private var installError: String?
    @State private var verifyOutput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            StepDots(current: step)
            Divider()
            Group {
                switch step {
                case .explain: explainView
                case .install: installView
                case .verify:  verifyView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack {
                Button("Close", role: .cancel) { onDone() }
                Spacer()
                if step != .explain {
                    Button("Back") {
                        step = SetupStep(rawValue: step.rawValue - 1) ?? .explain
                    }
                }
                Button(nextTitle) {
                    advance()
                }
                .buttonStyle(.borderedProminent)
                .disabled(nextDisabled)
            }
        }
        .padding(24)
        .frame(width: 560, height: 500)
    }

    private var info: AgentCatalog.Info? { AgentCatalog.info(forId: agentId) }

    // MARK: Subviews

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text("Set up \(info?.displayName ?? agentId)").font(.title2).bold()
                Text(info?.tier == .hook ? "Hook integration" : "MCP server integration")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var explainView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(explainBody).font(.body)
                Text("What DoomCoder will change on disk:")
                    .font(.callout).bold()
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(diskTargets, id: \.self) { line in
                        Label(line, systemImage: "folder.fill")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 8).fill(.regularMaterial)
                }
                Text("Every edit is backed up. Uninstall reverts the original.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var installView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Click **Install** to apply the changes above.")
            ScrollView {
                Text(installLog.isEmpty ? "Ready." : installLog)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 180)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.04))
            }
            if let err = installError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
            }
        }
    }

    private var verifyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fire a synthetic agent event through the real pipeline.")
            Button {
                fireVerify()
            } label: {
                Label("Send Test Notification", systemImage: "bell.badge.fill")
            }
            .buttonStyle(.borderedProminent)
            if !verifyOutput.isEmpty {
                Text(verifyOutput)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.04))
                    }
            }
            Text("If a channel isn't set up yet, configure it from iPhone Channels in the sidebar — then come back here.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Copy helpers

    private var explainBody: String {
        guard let info else { return "Unknown agent." }
        if info.tier == .hook {
            return "\(info.displayName) supports hooks — small shell commands it runs at key moments. DoomCoder adds a single entry to its config that pipes one JSON line per event to a local socket. Nothing leaves your machine. No tokens consumed."
        } else {
            return "\(info.displayName) supports MCP — an open protocol for tool integrations. DoomCoder adds a read-only MCP server entry to the agent's config. The agent calls it to announce lifecycle events. Runs locally, zero tokens."
        }
    }

    private var diskTargets: [String] {
        guard let info else { return [] }
        if info.tier == .hook, let hook = HookInstaller.Agent(rawValue: info.id) {
            return [
                HookInstaller.configPath(for: hook),
                "~/.doomcoder/hook.sh (runtime)",
                "~/.doomcoder/dc.sock (local socket)"
            ]
        }
        if info.tier == .mcp, let mcp = MCPInstaller.Agent.allCases.first(where: { $0.catalogId == info.id }) {
            return [
                mcp.configPath.path,
                "~/.doomcoder/mcp.py (runtime)"
            ]
        }
        return []
    }

    // MARK: Navigation

    private var nextTitle: String {
        switch step {
        case .explain: return "Continue"
        case .install: return installing ? "Installing…" : "Install"
        case .verify:  return "Finish"
        }
    }

    private var nextDisabled: Bool {
        switch step {
        case .install: return installing
        default:       return false
        }
    }

    private func advance() {
        switch step {
        case .explain: step = .install
        case .install:
            if installLog.contains("Done.") {
                step = .verify
            } else {
                runInstall()
            }
        case .verify:
            onDone()
        }
    }

    // MARK: Actions

    private func runInstall() {
        guard let info else { return }
        installing = true
        installError = nil
        installLog = ""
        append("• Starting install for \(info.displayName)…")
        Task {
            do {
                if info.tier == .hook, let hook = HookInstaller.Agent(rawValue: info.id) {
                    append("• Writing \(HookInstaller.configPath(for: hook))")
                    let result = try HookInstaller.install(hook)
                    append(result)
                } else if info.tier == .mcp, let mcp = MCPInstaller.Agent.allCases.first(where: { $0.catalogId == info.id }) {
                    append("• Writing \(mcp.configPath.path)")
                    _ = try MCPInstaller.install(mcp)
                    append("• Installed MCP server for \(mcp.displayName)")
                } else {
                    throw NSError(domain: "DoomCoder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported agent"])
                }
                append("Done.")
            } catch {
                installError = error.localizedDescription
                append("✗ \(error.localizedDescription)")
            }
            installing = false
        }
    }

    @MainActor
    private func append(_ line: String) {
        installLog += (installLog.isEmpty ? "" : "\n") + line
    }

    private func fireVerify() {
        guard let info else { return }
        // Inject a synthetic event through AgentStatusManager — the app
        // wires this to NotificationManager + IPhoneRelay, so this is the
        // real pipeline.
        NotificationCenter.default.post(
            name: .dcVerifySetup,
            object: nil,
            userInfo: ["agent": info.id]
        )
        verifyOutput = "Sent a synthetic 'wait' event. Check the menu bar and your configured iPhone channels. Delivery log shows results under System → Delivery Log."
    }
}

extension Notification.Name {
    static let dcVerifySetup = Notification.Name("dc.verify.setup")
}

// MARK: - ChannelSetupSheet

struct ChannelSetupSheet: View {
    let kind: AgentTrackingSelection.ChannelKind
    @Bindable var relay: IPhoneRelay
    let onDone: () -> Void

    @State private var step: SetupStep = .explain
    @State private var statusLine: String = ""
    @State private var verifyOutput: String = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            StepDots(current: step)
            Divider()
            Group {
                switch step {
                case .explain: explainView
                case .install: installView
                case .verify:  verifyView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                Button("Close", role: .cancel) { onDone() }
                Spacer()
                if step != .explain {
                    Button("Back") {
                        step = SetupStep(rawValue: step.rawValue - 1) ?? .explain
                    }
                }
                Button(nextTitle) { advance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.icon).font(.title).foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text("Set up \(kind.displayName)").font(.title2).bold()
                Text("3-step guided setup").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var explainBody: String {
        switch kind {
        case .calendar:
            return "DoomCoder creates a short event with a 3-second alarm on a dedicated DoomCoder calendar stored in iCloud. Every Apple device signed into your iCloud account — iPhone, iPad, Apple Watch — plays the alarm locally. This is the most reliable delivery mechanism Apple exposes: the alarm fires even if Focus is on, and never lands in Recently Deleted."
        case .ntfy:
            return "DoomCoder posts each notification to a private ntfy.sh topic. Install the ntfy iOS app and subscribe to your topic. Works even when you're not on the Apple ecosystem. Free."
        }
    }

    private var explainView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(explainBody)
            if kind == .calendar {
                Label("Uses EventKit + iCloud calendar sync. Ensure Settings → [Your Name] → iCloud → Calendars is ON on both devices.", systemImage: "icloud")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var installView: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch kind {
            case .calendar:
                Text("Click **Continue** to request Calendars access. macOS will prompt once. DoomCoder creates a 'DoomCoder' calendar on iCloud and uses it exclusively.")
                Toggle("Enable Calendar channel", isOn: Binding(
                    get: { relay.calendar.isEnabled },
                    set: { relay.calendar.isEnabled = $0 }
                ))
            case .ntfy:
                Text("Your private topic (random by default — keep it secret):")
                HStack {
                    TextField("doom-xxxxxxxxxx", text: Binding(
                        get: { relay.ntfy.topic },
                        set: { relay.ntfy.topic = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button("Generate") { relay.ntfy.generateTopicIfNeeded() }
                }
                Toggle("Enable ntfy channel", isOn: Binding(
                    get: { relay.ntfy.isEnabled },
                    set: { relay.ntfy.isEnabled = $0 }
                ))

                if let deepLink = relay.ntfy.deepLinkURL,
                   let subURL = relay.ntfy.subscriptionURL {
                    ntfyShareBox(deepLink: deepLink, subURL: subURL)
                }
            }
            if !statusLine.isEmpty {
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func ntfyShareBox(deepLink: URL, subURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subscribe on your iPhone")
                .font(.headline)
            Text("Install **ntfy** from the App Store. Inside the app, tap **+ Subscribe to topic** and enter:")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Topic row
            HStack(spacing: 8) {
                Text("Topic")
                    .font(.caption).bold()
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Text(relay.ntfy.topic)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(relay.ntfy.topic, forType: .string)
                    statusLine = "Topic copied."
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Copy topic")
            }
            .padding(10)
            .background { RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)) }

            // Server row
            HStack(spacing: 8) {
                Text("Server")
                    .font(.caption).bold()
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Text("ntfy.sh")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("ntfy.sh", forType: .string)
                    statusLine = "Server copied."
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Copy server")
            }
            .padding(10)
            .background { RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)) }

            Text("Leave **Server** as `ntfy.sh` (default) and paste **Topic** exactly. That's it — the next message DoomCoder fires will push to your phone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            DisclosureGroup("Alternate: one-tap share or QR") {
                VStack(spacing: 8) {
                    HStack {
                        Button {
                            let picker = NSSharingServicePicker(items: [subURL])
                            if let win = NSApp.keyWindow, let contentView = win.contentView {
                                picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
                            }
                        } label: {
                            Label("Share URL…", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(subURL.absoluteString, forType: .string)
                            statusLine = "Web URL copied."
                        } label: {
                            Label("Copy URL", systemImage: "link")
                        }
                    }
                    if let img = Self.qrImage(subURL.absoluteString) {
                        Image(nsImage: img)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 140, height: 140)
                        Text(subURL.absoluteString)
                            .font(.caption2)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        Text("(Camera app opens this in Safari — tap the Subscribe button on ntfy.sh.)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(8)
            }
            .padding(8)
            .background { RoundedRectangle(cornerRadius: 8).fill(.regularMaterial) }
        }
        .padding(12)
        .background { RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)) }
    }

    private var verifyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run a real end-to-end test.")
            HStack {
                Button {
                    runVerify()
                } label: {
                    Label("Run Test", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                if busy {
                    ProgressView().controlSize(.small)
                }
            }
            if !verifyOutput.isEmpty {
                Text(verifyOutput)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.04)) }
            }
        }
    }

    // MARK: Navigation

    private var nextTitle: String {
        switch step {
        case .explain: return "Continue"
        case .install: return "Continue"
        case .verify:  return "Finish"
        }
    }

    private func advance() {
        switch step {
        case .explain:
            if kind == .calendar {
                busy = true
                statusLine = "Requesting access…"
                Task {
                    let ok = await relay.calendar.requestAccess()
                    statusLine = ok ? "✓ Calendar access granted — DoomCoder calendar ready." : "✗ Access denied. Open System Settings → Privacy & Security → Calendars."
                    if ok { relay.calendar.isEnabled = true }
                    busy = false
                    step = .install
                }
            } else {
                relay.ntfy.generateTopicIfNeeded()
                step = .install
            }
        case .install:
            step = .verify
        case .verify:
            onDone()
        }
    }

    // MARK: Actions

    private func runVerify() {
        busy = true
        verifyOutput = "Sending…"
        Task {
            switch kind {
            case .calendar:
                let r = await relay.calendar.runICloudRoundTripTest()
                switch r {
                case .success(let latency):
                    verifyOutput = String(format: "✓ iCloud round-trip: %.2fs. In 3s your iPhone's alarm will fire.", latency)
                    relay.sendTest(channel: "Calendar")
                case .failure(let err):
                    verifyOutput = "✗ \(err.localizedDescription)"
                }
            case .ntfy:
                relay.sendTest(channel: "ntfy")
                try? await Task.sleep(for: .seconds(2))
                if let d = relay.deliveryLog.first(where: { $0.channel == "ntfy" }) {
                    verifyOutput = d.success ? "✓ \(d.detail). Check your ntfy iOS app." : "✗ \(d.detail)"
                } else {
                    verifyOutput = "Dispatched."
                }
            }
            busy = false
        }
    }

    // MARK: - QR

    static func qrImage(_ string: String) -> NSImage? {
        let data = Data(string.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
