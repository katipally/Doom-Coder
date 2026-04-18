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

// MARK: - AgentSetupStep (collapsed 2-step flow)
//
// v1.8.1: The old three-step Explain → Install → Verify flow duplicated the
// handshake wait (Install polled 30s inline, Verify fired a second test). The
// agent sheet now collapses to two steps: the Install step IS the verify —
// a single streaming log goes through preflight → write config → write rules
// → self-test → handshake → first tool call.

enum AgentSetupStep: Int, CaseIterable {
    case explain = 0, installAndVerify

    var title: String {
        switch self {
        case .explain:          return "What this does"
        case .installAndVerify: return "Install & Verify"
        }
    }
}

// MARK: - StepDots

private struct StepDots: View {
    let current: Int
    let steps: [(rawValue: Int, title: String)]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(steps.indices, id: \.self) { idx in
                let s = steps[idx]
                HStack(spacing: 6) {
                    Circle()
                        .fill(s.rawValue <= current ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 10, height: 10)
                    Text(s.title)
                        .font(.caption)
                        .foregroundStyle(s.rawValue == current ? .primary : .secondary)
                }
                if idx < steps.count - 1 {
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

    @State private var step: AgentSetupStep = .explain
    @State private var installLog: String = ""
    @State private var installing = false
    @State private var installError: String?
    @State private var installComplete = false
    @State private var showHowItWorks = false
    @State private var copyToast: String?
    @State private var waitingFor: String?   // e.g. "handshake from Cursor"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            StepDots(current: step.rawValue, steps: AgentSetupStep.allCases.map { ($0.rawValue, $0.title) })
            Divider()
            Group {
                switch step {
                case .explain:          explainView
                case .installAndVerify: installAndVerifyView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack {
                Button("Close", role: .cancel) { onDone() }
                Spacer()
                if step != .explain {
                    Button("Back") {
                        step = .explain
                    }
                    .disabled(installing)
                }
                Button(nextTitle) {
                    advance()
                }
                .buttonStyle(.borderedProminent)
                .disabled(nextDisabled)
            }
        }
        .padding(24)
        .frame(width: 600, height: 560)
        .overlay(alignment: .top) {
            if let toast = copyToast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(Color.green.opacity(0.4)))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: copyToast)
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
                Text("MCP server + rules snippet, verified end-to-end.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var explainView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(explainBody).font(.body)
                flowDiagram
                    .padding(.vertical, 4)
                howItWorksDisclosure
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

    // Mac ↔ Socket ↔ Agent diagram so users see what DoomCoder is waiting for.
    private var flowDiagram: some View {
        HStack(spacing: 0) {
            diagramNode(icon: "macbook", title: "Your Mac", subtitle: "DoomCoder")
            diagramArrow(label: "mcp.py")
            diagramNode(icon: "network", title: "Unix socket", subtitle: "dc.sock")
            diagramArrow(label: "dc tool")
            diagramNode(icon: "brain", title: info?.displayName ?? "Agent", subtitle: "calls dc")
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.2)))
    }

    private func diagramNode(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint)
            Text(title).font(.caption).bold()
            Text(subtitle).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func diagramArrow(label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "arrow.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
        }
        .frame(width: 60)
    }

    private var howItWorksDisclosure: some View {
        DisclosureGroup(isExpanded: $showHowItWorks) {
            VStack(alignment: .leading, spacing: 6) {
                Label("1. DoomCoder writes a tiny MCP server config into the agent's config file.",
                      systemImage: "1.circle")
                Label("2. A rules snippet tells the agent: 'before/after every turn, call the dc tool.'",
                      systemImage: "2.circle")
                Label("3. When the agent calls dc, DoomCoder sees it, keeps your Mac awake, and fires notifications.",
                      systemImage: "3.circle")
                Label("Minimal overhead — about 50 tokens per `dc` call. No network (unless you enable iPhone push). All local.",
                      systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .font(.caption)
            .padding(.top, 6)
        } label: {
            Label("What's happening? How DoomCoder talks to the agent.", systemImage: "questionmark.circle")
                .font(.callout.bold())
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private var installAndVerifyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !installComplete && !installing {
                Text("Click **Install & Verify** to apply the changes above and run a local pipeline self-test.")
            }
            ScrollView {
                Text(installLog.isEmpty ? "Ready." : installLog)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 200)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.04))
            }
            if installComplete && info?.id == "cursor" {
                cursorUserRulesCallout
            }
            if installComplete {
                nextStepsCallout
            }
            if let err = installError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
            }
        }
    }

    private var nextStepsCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Next step — restart the agent", systemImage: "arrow.clockwise.circle.fill")
                .font(.callout.bold())
                .foregroundStyle(.blue)
            Text(restartHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("DoomCoder will turn the agent row green as soon as the agent loads the config and makes its first `dc` call. If it doesn't flip in a minute, open the Doctor window to diagnose.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.blue.opacity(0.30), lineWidth: 1)
        }
    }

    private var restartHint: String {
        switch info?.id {
        case "cursor":         return "Quit Cursor (⌘Q) and reopen it. Start any chat — the first reply should make the row go green."
        case "copilot-cli":    return "Open a new terminal tab and run `copilot` again. The next reply should make the row go green."
        case "claude-code":    return "Close the current Claude Code session and start a new one. The next reply should make the row go green."
        case "windsurf":       return "Quit Windsurf and reopen it. Start any chat — the first reply should make the row go green."
        case "gemini-cli":     return "Open a new terminal tab and run `gemini` again. The next reply should make the row go green."
        case "codex":          return "Open a new terminal tab and run `codex` again. The next reply should make the row go green."
        default:               return "Fully quit and relaunch the agent so it picks up the new config."
        }
    }

    private var cursorUserRulesCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Cursor — paste the snippet into User Rules", systemImage: "lightbulb.fill")
                .font(.callout.bold())
                .foregroundStyle(.orange)
            Text("Cursor's project rule file (`~/.cursor/rules/doomcoder.mdc`) only auto-attaches inside your home folder. For every-project coverage, paste the snippet once into **Cursor → Settings → Rules → User Rules** — that setting isn't writable from outside the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(RulesInstaller.snippet, forType: .string)
                    showCopyToast("Snippet copied — paste into Cursor → Settings → Rules → User Rules")
                } label: {
                    Label("Copy snippet", systemImage: "doc.on.doc")
                }
                Button {
                    if let url = URL(string: "cursor://settings") {
                        NSWorkspace.shared.open(url)
                    } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") {
                        NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
                    }
                } label: {
                    Label("Open Cursor Settings", systemImage: "arrow.up.right.square")
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

    private func showCopyToast(_ msg: String) {
        copyToast = msg
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run { copyToast = nil }
        }
    }

    // MARK: Copy helpers

    private var explainBody: String {
        guard let info else { return "Unknown agent." }
        return "\(info.displayName) supports MCP — an open protocol for tool integrations. DoomCoder adds a read-only MCP server entry to the agent's config. The agent calls it once per reply to announce when it's done (or waiting on you). Runs locally; roughly 50 tokens per call."
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
        case .explain:
            return "Continue"
        case .installAndVerify:
            if installing { return "Working…" }
            return installComplete ? "Finish" : "Install & Verify"
        }
    }

    private var nextDisabled: Bool {
        switch step {
        case .installAndVerify: return installing
        default:                return false
        }
    }

    private func advance() {
        switch step {
        case .explain:
            step = .installAndVerify
        case .installAndVerify:
            if installComplete {
                onDone()
            } else {
                runInstall()
            }
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

                    // --- Verify: DoomCoder-side self-test only -------------
                    // v1.8.2: We no longer wait for the agent to send a real
                    // handshake or first tool call during install. Those are
                    // agent-dependent and users stared at a 2-minute progress
                    // bar before abandoning. Everything after this point is
                    // handled by the live pipeline: when the agent restarts
                    // and fires `mcp-hello` / `dc`, the sidebar flips green
                    // on its own. Deep diagnostics live in the Doctor window.
                    append("")
                    append("── Self-test ──")
                    append("• Can DoomCoder reach its own MCP script?")
                    if let sm = agentStatus {
                        let selfResult = await MCPRoundTripTest.selfTest(statusManager: sm)
                        switch selfResult {
                        case .failure(let f):
                            append("✗ Self-test failed: \(f.errorDescription ?? "unknown")")
                            append("  Socket pipeline is broken — open Doctor after closing this sheet.")
                            installError = "Self-test failed"
                            installing = false
                            return
                        case .success(let s):
                            append("✓ Self-test passed (\(s.millis) ms).")
                        }
                        // Mark the row configured as soon as files are on
                        // disk + self-test succeeds. Live promotion happens
                        // separately when `mcp-hello` arrives.
                        sm.markConfigured(info.id)
                        append("")
                        append("✓ Files are in place. \(mcp.displayName) will flip to 🟢 Live the moment it restarts and makes its first `dc` call. Run Doctor if it doesn't turn green.")
                    } else if MCPInstaller.status(for: mcp) == .live {
                        append("✓ MCP script installed. (No status manager attached — skipping live verify.)")
                    }
                } else {
                    throw NSError(domain: "DoomCoder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported agent"])
                }
                installComplete = true
                append("Done.")
            } catch {
                installError = error.localizedDescription
                append("✗ \(error.localizedDescription)")
            }
            waitingFor = nil
            installing = false
        }
    }

    @MainActor
    private func append(_ line: String) {
        installLog += (installLog.isEmpty ? "" : "\n") + line
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
            StepDots(current: step.rawValue, steps: SetupStep.allCases.map { ($0.rawValue, $0.title) })
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
        case .inMac:
            return "In-Mac Alert fires a loud system banner on this Mac when an agent needs attention, and loops a short sound so you can't miss it. No phone, no network, no setup beyond a one-time notification permission. Works even when DoomCoder isn't the front app."
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
            case .inMac:
                Text("DoomCoder needs permission to post notifications. macOS will prompt you the first time; you can always change your mind in **System Settings → Notifications → DoomCoder**.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("Alert sound duration")
                        .font(.caption).bold()
                    Picker("", selection: Binding(
                        get: { InMacAlert.shared.durationSeconds },
                        set: { InMacAlert.shared.durationSeconds = $0 }
                    )) {
                        Text("5 s").tag(5)
                        Text("7 s").tag(7)
                        Text("10 s").tag(10)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                .padding(8)
                .background { RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)) }
                Text("The banner's looping sound stops the moment you click or dismiss it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            case .inMac:
                // No per-channel seeding needed; UN auth is requested on
                // first real delivery via NotificationManager.
                step = .install
            case .ntfy:
                relay.ntfy.generateTopicIfNeeded()
                step = .install
            }
        case .install:
            step = .verify
        case .verify:
            // Ensure this channel becomes the active delivery method once
            // setup is complete, so the very next agent event actually lands.
            switch kind {
            case .inMac:
                relay.selectedChannelID = "inmac"
            case .ntfy:
                if relay.ntfy.isReady { relay.selectedChannelID = "ntfy" }
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
            case .inMac:
                relay.sendTest(channelID: "inmac")
                try? await Task.sleep(for: .milliseconds(500))
                verifyOutput = "✓ If you just heard a sound and saw a banner, the In-Mac channel is wired up. Click or dismiss the banner to stop the loop."
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
