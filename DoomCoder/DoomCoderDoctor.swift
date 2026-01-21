import SwiftUI
import AppKit
import UserNotifications

// MARK: - DoomCoderDoctor
//
// A one-glance diagnostics window. Probes every critical piece of the
// tracking pipeline (socket, hook script, MCP runtime, per-agent config,
// sentinels, accessibility permission, notifications, ntfy channel) and
// shows a coloured table. No actions, just honest answers.
//
// Surfaced via Window → DoomCoder Doctor.

struct DoomCoderDoctor: View {
    @Bindable var agentStatus: AgentStatusManager
    @Bindable var iPhoneRelay: IPhoneRelay
    var socketServer: SocketServer

    @State private var rows: [ProbeRow] = []
    @State private var running: Bool = false
    @State private var lastRunAt: Date? = nil
    @State private var axAuthorized: Bool = false
    @State private var notifAuthorized: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 640)
        .onAppear { Task { await runProbes() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("DoomCoder Doctor").font(.title3).bold()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await runProbes() }
            } label: {
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Re-run", systemImage: "arrow.clockwise")
                }
            }
            .disabled(running)

            Button {
                copyReport()
            } label: {
                Label("Copy report", systemImage: "doc.on.doc")
            }
        }
        .padding(16)
    }

    private var subtitle: String {
        if let at = lastRunAt {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            return "Last run \(f.localizedString(for: at, relativeTo: .now)) · \(failures) issue\(failures == 1 ? "" : "s")"
        }
        return running ? "Probing…" : "Ready."
    }

    private var failures: Int {
        rows.filter { $0.severity == .fail || $0.severity == .warn }.count
    }

    // MARK: Table

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    ProbeRowView(row: row)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    Divider()
                }
            }
        }
    }

    // MARK: Probes

    @MainActor
    private func runProbes() async {
        running = true
        defer { running = false; lastRunAt = .now }
        var r: [ProbeRow] = []

        r.append(ProbeRow(
            id: "socket",
            label: "Unix socket listening",
            severity: socketServer.isRunning ? .ok : .fail,
            detail: socketServer.isRunning
                ? socketServer.socketPath
                : "Socket server is not running — events cannot reach DoomCoder."
        ))

        let hookPath = HookRuntime.hookScriptURL.path
        let hookExists = FileManager.default.isExecutableFile(atPath: hookPath)
        r.append(ProbeRow(
            id: "hook-runtime",
            label: "Hook runtime script",
            severity: hookExists ? .ok : .fail,
            detail: hookExists ? hookPath : "Missing or not executable: \(hookPath)"
        ))

        let mcpPath = MCPRuntime.scriptURL.path
        let mcpExists = FileManager.default.isExecutableFile(atPath: mcpPath)
        r.append(ProbeRow(
            id: "mcp-runtime",
            label: "MCP runtime script",
            severity: mcpExists ? .ok : .fail,
            detail: mcpExists ? "\(mcpPath) (v\(MCPRuntime.version))" : "Missing or not executable: \(mcpPath)"
        ))

        for hook in HookInstaller.Agent.allCases {
            let status = HookInstaller.status(for: hook)
            let sev: ProbeSeverity
            let detail: String
            switch status {
            case .installed:
                let last = agentStatus.sessions.filter { $0.agent == hook.rawValue }.map(\.lastEventAt).max()
                sev = .ok
                detail = "Config at \(HookInstaller.configPath(for: hook))"
                    + (last.map { " · last event \(relative($0))" } ?? "")
            case .partial:
                sev = .warn
                detail = "Config found but incomplete — re-run setup."
            case .missingHookScript:
                sev = .fail
                detail = "Config points at a hook script that is missing."
            case .notInstalled:
                sev = .info
                detail = "Not installed."
            }
            r.append(ProbeRow(
                id: "hook-\(hook.rawValue)",
                label: "Hook · \(hook.displayName)",
                severity: sev,
                detail: detail
            ))
        }

        for mcp in MCPInstaller.Agent.allCases {
            let status = MCPInstaller.status(for: mcp)
            let live = agentStatus.lastHello(for: mcp.catalogId)
            let ttl: TimeInterval = 600
            let isLive = live.map { Date.now.timeIntervalSince($0) < ttl } ?? false
            let sev: ProbeSeverity
            let detail: String
            switch status {
            case .live:
                sev = .ok
                detail = "Live — " + (live.map { "last hello \(relative($0))" } ?? "recently")
            case .configWritten, .modified:
                sev = isLive ? .ok : .warn
                detail = "Config written but " + (isLive ? "live" : "no hello yet — quit and reopen the client (Cmd+Q).")
            case .missingConfig:
                sev = .fail
                detail = "Config missing on disk."
            case .notInstalled:
                sev = .info
                detail = "Not installed."
            }
            r.append(ProbeRow(
                id: "mcp-\(mcp.catalogId)",
                label: "MCP · \(mcp.displayName)",
                severity: sev,
                detail: detail
            ))
        }

        r.append(ProbeRow(
            id: "python3",
            label: "python3 at /usr/bin/python3",
            severity: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") ? .ok : .fail,
            detail: "Required by the MCP runtime."
        ))

        let trusted = AXIsProcessTrusted()
        axAuthorized = trusted
        r.append(ProbeRow(
            id: "accessibility",
            label: "Accessibility permission",
            severity: trusted ? .ok : .info,
            detail: trusted
                ? "Granted — DoomCoder can read GUI window titles for diagnostics."
                : "Not granted. DoomCoder still works; GUI window titles won't be shown in the Doctor."
        ))

        let notifSettings = await UNUserNotificationCenter.current().notificationSettings()
        notifAuthorized = notifSettings.authorizationStatus == .authorized
        r.append(ProbeRow(
            id: "notifications",
            label: "Local notifications",
            severity: notifAuthorized ? .ok : .warn,
            detail: notifAuthorized ? "Authorized." : "Not authorized — macOS banners will be suppressed."
        ))

        let ntfyReady = iPhoneRelay.ntfy.isReady
        r.append(ProbeRow(
            id: "ntfy",
            label: "ntfy channel",
            severity: ntfyReady ? .ok : .info,
            detail: ntfyReady ? "Ready." : "Not configured — iPhone alerts disabled."
        ))

        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".doomcoder", isDirectory: true)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: home.path, isDirectory: &isDir)
        r.append(ProbeRow(
            id: "doomcoder-dir",
            label: "~/.doomcoder directory",
            severity: (exists && isDir.boolValue) ? .ok : .fail,
            detail: (exists && isDir.boolValue) ? home.path : "Missing or not a directory."
        ))

        r.append(ProbeRow(
            id: "macos",
            label: "macOS version",
            severity: .info,
            detail: ProcessInfo.processInfo.operatingSystemVersionString
        ))

        rows = r
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: .now)
    }

    private func copyReport() {
        let lines = rows.map { r -> String in
            let tag: String
            switch r.severity {
            case .ok: tag = "[ OK ]"
            case .warn: tag = "[WARN]"
            case .fail: tag = "[FAIL]"
            case .info: tag = "[INFO]"
            }
            return "\(tag) \(r.label) — \(r.detail)"
        }
        let header = "DoomCoder Doctor — \(Date.now)\n"
        let text = header + lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - ProbeRow

private enum ProbeSeverity {
    case ok, warn, fail, info

    var colour: Color {
        switch self {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        case .info: return .secondary
        }
    }

    var icon: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }
}

private struct ProbeRow: Identifiable {
    let id: String
    let label: String
    let severity: ProbeSeverity
    let detail: String
}

private struct ProbeRowView: View {
    let row: ProbeRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.severity.icon)
                .foregroundStyle(row.severity.colour)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.label).font(.body)
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}
