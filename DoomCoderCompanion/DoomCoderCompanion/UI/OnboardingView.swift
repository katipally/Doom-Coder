// OnboardingView.swift — DoomCoder Companion
// First-run gate. Checks iCloud and notification permission.
// Mac visibility is a soft non-blocking warning — app proceeds even if no Mac yet.

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
        // Soft gate: iCloud + notifications must be OK.
        // Mac visibility is shown as warning but NOT blocking.
        icloudState == .ok && notifState == .ok
    }
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // App logo
            VStack(spacing: 8) {
                Image("logo-doomcoder")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                
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
                Text("DoomCoder uses notifications to tell you when an agent on your Mac needs your attention. No marketing, ever.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            
            if macState == .actionNeeded {
                VStack(spacing: 8) {
                    Text("⚠️ No Mac detected yet")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    Text("Open DoomCoder on your Mac first. The app will sync automatically once your Mac is running.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
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
        }
        .padding(.bottom, 32)
        .task { await runChecks() }
        .task(id: macState) {
            // Poll CloudKit while Mac is not yet visible so a new user who opens
            // iOS before the Mac has published doesn't stay stuck indefinitely.
            guard macState == .actionNeeded else { return }
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(3))
                await CompanionSyncEngine.shared.fetchChanges()
                if !macStore.byMacId.isEmpty { break }
            }
        }
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
