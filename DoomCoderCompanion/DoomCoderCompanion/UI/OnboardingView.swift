// OnboardingView.swift — DoomCoder Companion
// First-run gate. Checks iCloud account status, notification permission, and
// whether at least one Mac has synced. The Continue button unlocks once iCloud
// and notifications are ready.

import SwiftUI
import CloudKit
import UserNotifications
import DoomCoderCore

struct OnboardingView: View {

    let onComplete: () -> Void

    enum CheckState { case checking, ok, actionNeeded }

    @State private var icloudState: CheckState = .checking
    @State private var notifState:  CheckState = .checking
    @State private var macState:    CheckState = .checking
    @State private var macStore = MacStatusStore.shared

    private var canContinue: Bool {
        // v3.2 — STRICT gate. All three signals must be green before the
        // user lands on the main UI; otherwise the empty-state scenarios
        // we polished out of HomeView reappear here and confuse first-run
        // users into thinking the app is broken.
        //
        // ⚠ App-Review note: blocking the app behind an external-device
        // signal (Mac visible) carries some risk. If reviewers reject the
        // build, soften this to icloud + notif only and surface the Mac
        // requirement as a non-blocking warning row.
        icloudState == .ok && notifState == .ok && macState == .ok
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App logo / wordmark
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.accentColor.gradient)
                        .frame(width: 96, height: 96)
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                }

                Text("DoomCoder")
                    .font(.largeTitle.bold())
                Text("Companion")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            // Status rows
            VStack(spacing: 16) {
                StatusRow(label: "iCloud signed in", state: icloudState, actionLabel: "Open Settings") {
                    openSettings()
                }
                StatusRow(label: "Notifications enabled", state: notifState, actionLabel: "Enable") {
                    Task { await requestNotifications() }
                }
                StatusRow(label: "Mac visible", state: macState, actionLabel: nil, action: nil)
            }
            .padding(.horizontal)

            if notifState == .actionNeeded {
                Text("DoomCoder uses notifications to tell you when an agent on your Mac needs your attention — finished a task, hit a permission prompt, or errored out. No marketing pings, ever.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            if macState == .actionNeeded {
                Text("Open DoomCoder on your Mac first — the iPhone app will sync once it sees the Mac.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            Spacer()

            Button("Continue") {
                AppGroupCache.defaults.set(Date(), forKey: "onboarding.completedAt")
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canContinue)
            .padding(.horizontal)

            #if DEBUG
            // Debug-only escape hatch for QA / TestFlight builds. Hidden on
            // Release. Lets us bypass the strict gate when a sim has no
            // paired Mac available.
            Button("Continue anyway (DEBUG)") {
                AppGroupCache.defaults.set(Date(), forKey: "onboarding.completedAt")
                onComplete()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
            #endif
        }
        .padding(.bottom, 32)
        .task { await runChecks() }
        .onChange(of: macStore.byMacId.count) { _, count in
            macState = count > 0 ? .ok : .actionNeeded
        }
    }

    // MARK: - Checks

    private func runChecks() async {
        await checkiCloud()
        await checkNotifications()
        macState = macStore.byMacId.isEmpty ? .actionNeeded : .ok
    }

    private func checkiCloud() async {
        do {
            let status = try await CKContainer(identifier: CloudKitConstants.containerIdentifier)
                .accountStatus()
            icloudState = status == .available ? .ok : .actionNeeded
        } catch {
            icloudState = .actionNeeded
        }
    }

    private func checkNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notifState = .ok
        case .notDetermined:
            // v3.0: do NOT auto-prompt. Show the "Enable" button and let the
            // user tap it after they've read why DoomCoder needs notifications.
            notifState = .actionNeeded
        default:
            notifState = .actionNeeded
        }
    }

    private func requestNotifications() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        notifState = granted ? .ok : .actionNeeded
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - StatusRow

private struct StatusRow: View {
    let label: String
    let state: OnboardingView.CheckState
    let actionLabel: String?
    let action: (() -> Void)?

    var body: some View {
        HStack {
            stateIcon
            Text(label)
            Spacer()
            if state == .actionNeeded, let label = actionLabel, let action {
                Button(label, action: action)
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch state {
        case .checking:
            ProgressView().controlSize(.small)
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .actionNeeded:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        }
    }
}
