import SwiftUI
import AppKit

/// Settings pane embedded as the 4th tab of the Configure window. Replaces
/// the standalone `SettingsView` window scene. Every control here backs a
/// real, persistent preference — no stubs.
struct ConfigureSettingsPane: View {
    @Bindable var sleepManager: SleepManager
    @State private var autoRevertSeconds: Int = {
        UserDefaults.standard.object(forKey: "doomcoder.session.autoRevertSeconds") as? Int ?? 30
    }()
    @State private var redact: Bool = {
        UserDefaults.standard.object(forKey: "doomcoder.agents.redact") as? Bool ?? true
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(.title.bold())
                    .padding(.top, 8)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Launch at Login", isOn: Binding(
                            get: { sleepManager.isLaunchAtLoginEnabled },
                            set: { _ in sleepManager.toggleLaunchAtLogin() }
                        ))
                        Divider()
                        HStack {
                            Text("Open DoomCoder")
                            Spacer()
                            Text(GlobalHotkey.shared.current.descriptionForUI)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if GlobalHotkey.shared.conflictDetected {
                            Label(
                                "Another app may be using this shortcut. It won't fire until you change it.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                            .font(.caption)
                        } else {
                            Text("Works anywhere — no extra permission needed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("General", systemImage: "gear")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Stepper(value: $sleepManager.screenOffRearmMinutes, in: 1...60) {
                            HStack {
                                Text("Re-sleep display after")
                                HelpTip("After you move the mouse to wake the display in Screen Off mode, DoomCoder will put it back to sleep again after this many minutes of idle time.")
                                Spacer()
                                Text("\(sleepManager.screenOffRearmMinutes) min idle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Screen Off", systemImage: "moon.fill")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Stepper(value: $autoRevertSeconds, in: 10...120, step: 5) {
                            HStack {
                                Text("Auto-revert completed sessions to idle after")
                                HelpTip("How long the 'completed' or 'failed' status badge stays on an agent row before it automatically reverts to 'idle'. Increase this if you miss notifications.")
                                Spacer()
                                Text("\(autoRevertSeconds)s")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onChange(of: autoRevertSeconds) { _, new in
                            UserDefaults.standard.set(new, forKey: "doomcoder.session.autoRevertSeconds")
                        }
                        Text("How long the badge shows \"completed\" or \"failed\" before reverting to \"idle\".")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Session Lifecycle", systemImage: "clock.arrow.circlepath")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Toggle("Redact prompt text in local history", isOn: $redact)
                                .onChange(of: redact) { _, new in
                                    UserDefaults.standard.set(new, forKey: "doomcoder.agents.redact")
                                }
                            HelpTip("Hides agent prompt and response content in the local event log and Logs view. Event type, timing, and status are still recorded. Enabled by default for privacy.")
                        }
                        Divider()
                        companionBanner
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Notifications & Privacy", systemImage: "bell.badge")
                }

                GroupBox {
                    Button("Reveal Logs") { NSWorkspace.shared.open(AgentLogDir.url) }
                        .buttonStyle(.bordered)
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var companionBanner: some View {
        let isReady = CloudKitPusher.shared.isReady
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 26))
                .foregroundStyle(isReady ? Color.accentColor : .secondary)
                .frame(width: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("DoomCoder for iPhone & iPad")
                        .font(.body.weight(.semibold))
                    Spacer()
                    Image(systemName: isReady ? "checkmark.icloud.fill" : "icloud.slash")
                        .foregroundStyle(isReady ? .green : .secondary)
                        .accessibilityHidden(true)
                    Text(isReady ? "iCloud connected" : "Connecting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Mirror every agent notification, see installed-agent status, and read session logs from your phone. Notifications are delivered through your private iCloud — no servers, no tokens, no QR codes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        if let url = URL(string: Self.companionAppStoreURL) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Get on the App Store", systemImage: "arrow.down.app.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        if let url = URL(string: Self.companionHelpURL) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Text("How it works")
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
                Text("Sign in to the same iCloud account on your Mac and your iPhone. The agent list and notifications appear automatically.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    private static let companionAppStoreURL =
        "https://apps.apple.com/app/doomcoder-companion/id6772514212"
    private static let companionHelpURL =
        "https://github.com/katipally/Doom-Coder#iphone--ipad-companion"
}
