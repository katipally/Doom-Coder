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
                        Label("Another app may be using this shortcut. It won't fire until you change it.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    } else {
                        Text("Works anywhere — no extra permission needed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("General", systemImage: "gear")
                }

                GroupBox {
                    Stepper(value: $sleepManager.screenOffRearmMinutes, in: 1...60) {
                        HStack {
                            Text("Re-sleep display after")
                            Spacer()
                            Text("\(sleepManager.screenOffRearmMinutes) min idle")
                                .foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Label("Screen Off", systemImage: "moon.fill")
                }

                GroupBox {
                    Stepper(value: $autoRevertSeconds, in: 10...120, step: 5) {
                        HStack {
                            Text("Auto-revert completed sessions to idle after")
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
                } label: {
                    Label("Session Lifecycle", systemImage: "clock.arrow.circlepath")
                }

                GroupBox {
                    Toggle("Redact prompt text in local history", isOn: $redact)
                        .onChange(of: redact) { _, new in
                            UserDefaults.standard.set(new, forKey: "doomcoder.agents.redact")
                        }
                    Divider()
                    companionBanner
                } label: {
                    Label("Notifications & Privacy", systemImage: "bell.badge")
                }

                GroupBox {
                    HStack {
                        Button("Reveal Logs") { NSWorkspace.shared.open(AgentLogDir.url) }
                        Spacer()
                    }
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

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("DoomCoder for iPhone & iPad")
                        .font(.body.weight(.semibold))
                    Spacer()
                    Image(systemName: isReady ? "checkmark.icloud.fill" : "icloud.slash")
                        .foregroundStyle(isReady ? .green : .secondary)
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
