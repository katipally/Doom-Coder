import AppKit
import ApplicationServices
import SwiftUI

// Accessibility permission helpers.
//
// Note: Our default global hotkey path (Carbon's RegisterEventHotKey)
// does NOT require Accessibility permission. It's only needed if the
// user configures a shortcut that conflicts with a reserved key or
// wants the hotkey to suppress the original keystroke in other contexts.
//
// We still surface a guided flow so the user understands the permission
// implications and can grant it if they want CGEventTap-based features
// (e.g., cursor-anchored panel in the future) to work.
@MainActor
enum AccessibilityPermission {
    /// Returns true if the app is in the AX trusted list.
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user to grant access; opens System Settings if the
    /// prompt dialog is insufficient. The boolean returned is the
    /// current trust status (which may be false even after prompting,
    /// since the user still needs to flip the toggle in Settings).
    @discardableResult
    static func promptForTrust() -> Bool {
        // Use the string literal directly to avoid Swift 6 concurrency
        // diagnostic on the global `kAXTrustedCheckOptionPrompt` CFString var.
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts: [CFString: Any] = [key: true]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    /// Deep-link to Privacy → Accessibility.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Poll every 1s for `timeout` seconds; calls completion with the
    /// final trust state. Useful for refreshing UI after the user toggles
    /// the switch in System Settings.
    static func pollUntilTrusted(timeout: TimeInterval = 30,
                                 completion: @escaping @MainActor (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        Task { @MainActor in
            while Date() < deadline {
                if AXIsProcessTrusted() {
                    completion(true)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            completion(AXIsProcessTrusted())
        }
    }
}

// MARK: - Guided sheet

struct AccessibilityPermissionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var trusted: Bool = AccessibilityPermission.isTrusted()
    @State private var polling: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Global Shortcut")
                        .font(.title2.weight(.semibold))
                    Text("DoomCoder can open instantly from anywhere.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label("The default shortcut ⌥ Space works without extra permission.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("Accessibility is only required for advanced gestures (future).",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            if trusted {
                Label("Accessibility is granted.", systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Optionally grant Accessibility:")
                        .font(.callout.weight(.semibold))
                    Text("1. Click “Open System Settings” below.")
                    Text("2. Enable DoomCoder in the Accessibility list.")
                    Text("3. Return here — the status will refresh automatically.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button("Open System Settings") {
                    AccessibilityPermission.openSystemSettings()
                    startPolling()
                }
                .disabled(trusted)

                if polling && !trusted {
                    ProgressView().controlSize(.small)
                    Text("Waiting for grant…").font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear { trusted = AccessibilityPermission.isTrusted() }
    }

    private func startPolling() {
        polling = true
        AccessibilityPermission.pollUntilTrusted { ok in
            trusted = ok
            polling = false
        }
    }
}
