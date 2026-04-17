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
    var agentStatus: AgentStatusManager? = nil

    @State private var step: SetupStep = .explain
    @State private var installLog: String = ""
    @State private var installing = false
    @State private var installError: String?
    @State private var verifyOutput: String = ""
    @State private var verifying = false

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
                Text("MCP server integration")
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
            if info?.id == "cursor" {
                cursorUserRulesCallout
            }
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

    private var cursorUserRulesCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Cursor requires one extra paste for global coverage", systemImage: "lightbulb.fill")
                .font(.callout.bold())
                .foregroundStyle(.orange)
            Text("Cursor's project rules file only auto-attaches inside your home folder. To make DoomCoder work in every project, also paste the snippet into Cursor → Settings → Rules → User Rules.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(RulesInstaller.snippet, forType: .string)
                } label: {
                    Label("Copy snippet", systemImage: "doc.on.doc")
                }
                Button {
                    if let url = URL(string: "cursor://settings") {
                        NSWorkspace.shared.open(url)
                    } else {
                        NSWorkspace.shared.launchApplication("Cursor")
                    }
                } label: {
                    Label("Open Cursor", systemImage: "arrow.up.right.square")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        }
    }

    private var verifyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fire a real round-trip event: DoomCoder will run the MCP server script and wait for the event to arrive on the Unix socket. Typical round-trip is 10–40 ms.")
            Button {
                fireVerify()
            } label: {
                if verifying {
                    Label("Running…", systemImage: "hourglass")
                } else {
                    Label("Run Round-Trip Test", systemImage: "bolt.horizontal.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(verifying)
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
        return "\(info.displayName) supports MCP — an open protocol for tool integrations. DoomCoder adds a read-only MCP server entry to the agent's config. The agent calls it to announce lifecycle events. Runs locally, zero tokens."
    }

    private var diskTargets: [String] {
        guard let info else { return [] }
        if let mcp = MCPInstaller.Agent.allCases.first(where: { $0.catalogId == info.id }) {
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
                if let mcp = MCPInstaller.Agent.allCases.first(where: { $0.catalogId == info.id }) {
                    // Preflight first so warnings (e.g. Cursor project shadows)
                    // are visible to the user. Blockers will raise below from
                    // MCPInstaller.install itself — we surface them here too so
                    // the log reads nicely rather than just a raw error string.
                    let issues = MCPInstaller.preflight(mcp)
                    for issue in issues {
                        let marker = issue.severity == .blocker ? "✗" : "⚠︎"
                        append("\(marker) \(issue.summary)")
                        for line in issue.detail.split(separator: "\n") {
                            append("    \(line)")
                        }
                    }
                    append("• Writing \(mcp.configPath.path)")
                    _ = try MCPInstaller.install(mcp)
                    append("• Installed MCP server for \(mcp.displayName)")

                    // Three-part install contract: config + rules snippet +
                    // real verification. Without the rules snippet the agent
                    // knows the tool exists but has no reason to call it.
                    if let ri = RulesInstaller.Agent(rawValue: info.id) {
                        for p in ri.rulesPaths {
                            append("• Writing rules snippet to \(p.path)")
                        }
                        do {
                            _ = try RulesInstaller.install(ri)
                            let style = ri.strategy == .standalone ? "standalone" : "appended"
                            let count = ri.rulesPaths.count
                            append("✓ Rules snippet installed (\(style), \(count) path\(count == 1 ? "" : "s")).")
                            if ri == .cursor {
                                append("ℹ︎ Cursor note: the rule lives at ~/.cursor/rules/doomcoder.mdc which")
                                append("  only auto-attaches for projects rooted at your home folder. For")
                                append("  every-project coverage, also paste the snippet once into Cursor →")
                                append("  Settings → Rules → User Rules (Cursor's user-rules aren't writable")
                                append("  from outside the app as of April 2026).")
                            }
                        } catch {
                            append("⚠︎ Rules install failed: \(error.localizedDescription)")
                            append("  The MCP config is still in place; you can retry from the doctor pane.")
                        }
                    } else {
                        append("• No rules file for this agent — config alone is enough.")
                    }

                    append("• Restart \(mcp.displayName) so it picks up the new config + rules.")
                    append("  Waiting up to 30s for a handshake…")
                    // Gate 1: mcp-hello proves the agent loaded the config.
                    // Gate 2: a real `dc` tool call proves the rules snippet
                    // was read. Both are required for a true green.
                    let since = Date.now
                    var gotHello = false
                    var gotToolCall = false
                    if let sm = agentStatus {
                        for _ in 0..<60 {
                            try? await Task.sleep(for: .milliseconds(500))
                            if !gotHello, let h = sm.lastHello(for: info.id), h >= since {
                                gotHello = true
                                append("✓ Handshake received — \(mcp.displayName) loaded the config.")
                            }
                            if gotHello, let t = sm.lastToolCall(for: info.id), t >= since {
                                gotToolCall = true
                                append("✓ Rules honored — \(mcp.displayName) called `dc`.")
                                break
                            }
                        }
                    } else if MCPInstaller.status(for: mcp) == .live {
                        gotHello = true
                    }
                    if !gotHello {
                        append("⚠︎ No handshake yet. Restart \(mcp.displayName); the next turn should flip the badge to 🟢 Configured.")
                    } else if !gotToolCall {
                        append("⚠︎ Config loaded but rules not honored yet. Start a new turn in \(mcp.displayName); it should call `dc` on its first move.")
                    }
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
        // Every agent is MCP: spawn mcp.py ourselves for the self-test
        // (proves the script + socket pipeline is healthy), then poll for
        // hello + first real `dc` tool call from the actual agent.
        if let sm = agentStatus {
            verifying = true
            verifyOutput = "Self-testing mcp.py → dc.sock…"
            Task {
                defer { verifying = false }
                let self_ = await MCPRoundTripTest.selfTest(statusManager: sm)
                switch self_ {
                case .failure(let f):
                    verifyOutput = "✗ Self-test failed: \(f.errorDescription ?? "unknown").\nThis means DoomCoder can't speak to its own MCP script. Fix this before restarting the IDE."
                    return
                case .success(let s):
                    verifyOutput = "✓ Self-test passed (\(s.millis) ms).\nNow waiting for \(info.displayName) to connect (≤30s)…"
                }
                let since = Date.now
                let hello = await MCPRoundTripTest.awaitAgentHandshake(
                    agentId: info.id, since: since, timeout: 30, statusManager: sm)
                switch hello {
                case .failure(let f):
                    verifyOutput += "\n✗ \(f.errorDescription ?? "no handshake")"
                    return
                case .success:
                    // Handshake alone is enough to flip the sticky
                    // "configured" flag — the user has proven the host
                    // agent loaded our MCP config. Waiting for a tool
                    // call is still useful (confirms rules were read)
                    // but not required for the Track UI to unlock.
                    sm.markConfigured(info.id)
                    verifyOutput += "\n✓ Handshake received — config loaded."
                }
                let tool = await MCPRoundTripTest.awaitFirstToolCall(
                    agentId: info.id, since: since, timeout: 30, statusManager: sm)
                switch tool {
                case .success:
                    verifyOutput += "\n✓ Rules honored — \(info.displayName) called `dc`. Setup complete."
                case .failure(let f):
                    verifyOutput += "\n⚠︎ \(f.errorDescription ?? "rules not honored yet")"
                }
            }
            return
        }

        verifyOutput = "No verifier available for this agent type."
    }
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
        case .ntfy:
            return "DoomCoder posts each notification to a private ntfy.sh topic. Install the ntfy iOS app and subscribe to your topic. Works even when you're not on the Apple ecosystem. Free."
        }
    }

    private var explainView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(explainBody)
        }
    }

    private var installView: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch kind {
            case .ntfy:
                Text("Your private topic (random by default — keep it secret):")
                HStack {
                    TextField("dc-xxxxxxxx", text: Binding(
                        get: { relay.ntfy.topic },
                        set: { relay.ntfy.topic = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button("Generate") { relay.ntfy.generateTopicIfNeeded() }
                }

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
            switch kind {
            case .ntfy:
                relay.ntfy.generateTopicIfNeeded()
                step = .install
            }
        case .install:
            step = .verify
        case .verify:
            // Ensure this channel becomes the active delivery method once
            // setup is complete, so the very next agent event actually lands.
            if relay.ntfy.isReady {
                switch kind {
                case .ntfy: relay.selectedChannelID = "ntfy"
                }
            }
            onDone()
        }
    }

    // MARK: Actions

    private func runVerify() {
        busy = true
        verifyOutput = "Sending…"
        Task {
            switch kind {
            case .ntfy:
                relay.sendTest(channelID: "ntfy")
                try? await Task.sleep(for: .seconds(2))
                if let d = relay.deliveryLog.first(where: { $0.channel == "ntfy.sh" }) {
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
