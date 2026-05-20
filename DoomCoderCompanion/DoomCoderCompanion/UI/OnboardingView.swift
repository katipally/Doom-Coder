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
        icloudState == .ok && notifState == .ok
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App logo / wordmark
            VStack(spacing: 8) {
                Image("AppIcon")      // from Assets.xcassets
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

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
            .padding(.bottom, 32)
        }
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
            await requestNotifications()
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
