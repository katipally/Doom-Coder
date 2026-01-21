import SwiftUI
import AppKit

// MARK: - InstallAnywherePane
//
// Marketplace-style UI for connecting DoomCoder's MCP server to any MCP-capable
// client (Cursor, Windsurf, Claude Desktop, Zed, VS Code, custom, etc.). The
// user picks a client, copies the ready-made JSON snippet, pastes it into the
// client's config, restarts it, and hits Verify. We poll the MCP hello stream
// for an `mcp-hello` event carrying `--agent custom` and turn green on arrival.
//
// This is the escape hatch for every agent we don't have a dedicated installer
// for. Zero per-client code; one config snippet + copy-paste.

struct InstallAnywherePane: View {
    @Bindable var agentStatus: AgentStatusManager

    @State private var selectedClient: ClientKind = .cursor
    @State private var copied: Bool = false
    @State private var verifying: Bool = false
    @State private var verifyResult: VerifyResult = .idle
    @State private var verifyStartedAt: Date? = nil
    @State private var verifyTask: Task<Void, Never>? = nil

    private let customAgent = "custom"
    private let verifyTimeout: TimeInterval = 120

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                snippetCard
                Divider()
                clientPicker
                Divider()
                instructions
                Divider()
                verifyCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { verifyTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Install Anywhere").font(.title).bold()
            Text("Paste this MCP server into any client that speaks the MCP protocol. DoomCoder will show a live handshake as soon as the client loads the config.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Snippet

    private var snippetJSON: String {
        let scriptPath = MCPRuntime.scriptURL.path
        return """
        {
          "mcpServers": {
            "doomcoder": {
              "command": "/usr/bin/python3",
              "args": [
                "\(scriptPath)",
                "--agent", "\(customAgent)"
              ],
              "env": {}
            }
          }
        }
        """
    }

    private var snippetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MCP server config").font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippetJSON, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy JSON",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(snippetJSON)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .textBackgroundColor))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    }
            }
        }
    }

    // MARK: - Client picker

    private var clientPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick your client").font(.headline)
            Picker("", selection: $selectedClient) {
                ForEach(ClientKind.allCases) { c in
                    Text(c.displayName).tag(c)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - Instructions

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedClient.displayName).font(.headline)
            ForEach(Array(selectedClient.steps.enumerated()), id: \.offset) { idx, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(idx + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(step)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let note = selectedClient.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Verify

    private var verifyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Verify").font(.headline)
            Text("After pasting the config and fully restarting your client, press Verify. DoomCoder listens for the handshake for up to \(Int(verifyTimeout)) seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    startVerify()
                } label: {
                    if verifying {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for handshake…")
                        }
                    } else {
                        Label("Verify connection", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(verifying)

                if verifying {
                    Button("Cancel") {
                        verifyTask?.cancel()
                        verifying = false
                        verifyResult = .idle
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }

            resultBanner
        }
    }

    @ViewBuilder
    private var resultBanner: some View {
        switch verifyResult {
        case .idle:
            EmptyView()
        case .success(let clientName, let ms):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Handshake received in \(ms) ms").bold()
                    Text(clientName.isEmpty ? "Client identified itself via initialize." : "Client: \(clientName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.08))
            }
        case .timeout:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No handshake received").bold()
                    Text("Confirm you fully quit and reopened the client (Cmd+Q, not just close the window). On Cursor/Windsurf, check for a project-level .cursor/mcp.json that shadows the global config.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08))
            }
        }
    }

    // MARK: - Verify logic

    private func startVerify() {
        verifyTask?.cancel()
        verifying = true
        verifyResult = .idle
        let startedAt = Date.now
        verifyStartedAt = startedAt
        let baseline = agentStatus.lastHello(for: customAgent) ?? .distantPast
        let deadline = startedAt.addingTimeInterval(verifyTimeout)

        verifyTask = Task { @MainActor in
            while !Task.isCancelled && Date.now < deadline {
                if let last = agentStatus.lastHello(for: customAgent), last > baseline {
                    let ms = Int(last.timeIntervalSince(startedAt) * 1000)
                    let clientName = MCPInstaller.lastClientName(for: customAgent) ?? ""
                    verifyResult = .success(clientName: clientName, ms: max(ms, 0))
                    verifying = false
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            if !Task.isCancelled {
                verifyResult = .timeout
                verifying = false
            }
        }
    }

    // MARK: - Types

    private enum VerifyResult: Equatable {
        case idle
        case success(clientName: String, ms: Int)
        case timeout
    }

    enum ClientKind: String, CaseIterable, Identifiable {
        case cursor, windsurf, claudeDesktop, vsCode, zed, custom

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .cursor: return "Cursor"
            case .windsurf: return "Windsurf"
            case .claudeDesktop: return "Claude Desktop"
            case .vsCode: return "VS Code"
            case .zed: return "Zed"
            case .custom: return "Custom"
            }
        }

        var steps: [String] {
            switch self {
            case .cursor:
                return [
                    "Open Cursor → Settings → MCP Servers (or edit ~/.cursor/mcp.json).",
                    "Paste the snippet above. If a doomcoder entry already exists, replace it.",
                    "Save the file.",
                    "Quit Cursor completely (Cmd+Q) and reopen it. A window-close is not enough.",
                    "Come back here and press Verify."
                ]
            case .windsurf:
                return [
                    "Open Windsurf → Settings → MCP (or edit ~/.codeium/windsurf/mcp_config.json).",
                    "Paste the snippet into the mcpServers object.",
                    "Save and fully restart Windsurf.",
                    "Come back here and press Verify."
                ]
            case .claudeDesktop:
                return [
                    "Open Claude → Settings → Developer → Edit Config.",
                    "Paste the snippet (it's the exact format claude_desktop_config.json expects).",
                    "Quit Claude (Cmd+Q) and reopen it.",
                    "Come back here and press Verify."
                ]
            case .vsCode:
                return [
                    "In VS Code, open the Command Palette and run \"MCP: Open User Configuration\".",
                    "Paste the snippet. VS Code accepts the same mcpServers object.",
                    "Reload the window (Cmd+Shift+P → \"Developer: Reload Window\").",
                    "Come back here and press Verify."
                ]
            case .zed:
                return [
                    "Open Zed → Settings → Open settings.json.",
                    "Under \"context_servers\" (or \"mcp\"), paste the snippet's server entry.",
                    "Save and restart Zed.",
                    "Come back here and press Verify."
                ]
            case .custom:
                return [
                    "Any MCP-capable client works. The snippet above is the standard mcpServers object.",
                    "Most clients accept either the full object (with \"mcpServers\") or just the inner \"doomcoder\" entry — check your client's docs.",
                    "Restart the client so it re-reads its config.",
                    "Come back here and press Verify."
                ]
            }
        }

        var note: String? {
            switch self {
            case .cursor, .windsurf:
                return "Heads up: a project-level .cursor/mcp.json (or equivalent) overrides the global config silently. DoomCoder auto-detects these during install — check Cursor/Windsurf in the sidebar if Verify keeps timing out."
            case .vsCode:
                return "Requires VS Code 1.95+ with MCP support enabled."
            default:
                return nil
            }
        }
    }
}

// MARK: - MCPInstaller.lastClientName helper
//
// Used by Verify to show which client actually loaded the config, not just
// that something did. Reads the most recent clientInfo.name we recorded
// (stamped by the mcp.py v4 hello).

extension MCPInstaller {
    static func lastClientName(for agent: String) -> String? {
        let key = "dc.mcp.clientName.\(agent)"
        return UserDefaults.standard.string(forKey: key)
    }

    static func recordClientName(agent: String, clientName: String) {
        guard !clientName.isEmpty else { return }
        let key = "dc.mcp.clientName.\(agent)"
        UserDefaults.standard.set(clientName, forKey: key)
    }
}
