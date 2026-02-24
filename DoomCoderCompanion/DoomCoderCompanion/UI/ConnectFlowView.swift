// ConnectFlowView.swift — DoomCoder Companion
// AirDrop-style connect sheet: check iCloud → look for Macs → pick one (auto-
// select if there's only one) → connected → (contextually) ask for notifications.
//
// This is the ONLY place we request notification permission, and only AFTER a
// Mac is connected — notifications are meaningless without one. The app remains
// fully usable if the user dismisses this at any step.

import SwiftUI
import CloudKit
import UserNotifications
import DoomCoderCore

struct ConnectFlowView: View {
    let onFinished: () -> Void

    enum Step {
        case checkingiCloud
        case icloudNeeded
        case searching
        case picker
        case noMacs
        case connected
        case notifications
    }

    @State private var step: Step = .checkingiCloud
    @State private var macStore = MacStatusStore.shared
    @State private var notifKnown = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer(minLength: 8)
                content
                Spacer()
            }
            .padding(24)
            .navigationTitle("Connect your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { finish() }
                }
            }
            .task { await begin() }
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .checkingiCloud:
            phase(symbol: "icloud", title: "Checking iCloud…",
                  detail: "DoomCoder uses your private iCloud to sync with your Mac.",
                  showSpinner: true)

        case .icloudNeeded:
            phase(symbol: "icloud.slash", title: "Sign in to iCloud",
                  detail: "To connect your Mac, sign in to iCloud in the Settings app, then come back and try again.")
            VStack(spacing: 12) {
                Button("Open Settings") { openSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Try Again") { Task { await begin() } }
                Button("Explore without a Mac") { finish() }
                    .foregroundStyle(.secondary)
            }

        case .searching:
            phase(symbol: "antenna.radiowaves.left.and.right", title: "Looking for your Mac…",
                  detail: "Make sure the DoomCoder app is open on your Mac and signed in to the same iCloud account.",
                  showSpinner: true)

        case .picker:
            phase(symbol: "macbook.and.iphone", title: "Choose your Mac",
                  detail: "Select which Mac to connect to.")
            VStack(spacing: 10) {
                ForEach(Array(macStore.byMacId.values).sorted { $0.lastSeen > $1.lastSeen }, id: \.macId) { mac in
                    Button {
                        select(mac.macId)
                    } label: {
                        HStack {
                            Image(systemName: "desktopcomputer")
                            VStack(alignment: .leading) {
                                Text(mac.name).font(.headline)
                                Text("Last seen \(mac.lastSeen, style: .relative) ago")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

        case .noMacs:
            phase(symbol: "questionmark.circle", title: "No Mac found yet",
                  detail: "Open DoomCoder on your Mac, sign in to the same iCloud account, then try again. You can keep using this app in the meantime.")
            VStack(spacing: 12) {
                Button("Try Again") { Task { await begin() } }
                    .buttonStyle(.borderedProminent)
                Link("Download DoomCoder for Mac",
                     destination: URL(string: "https://github.com/katipally/Doom-Coder/releases")!)
                Button("Explore without a Mac") { finish() }
                    .foregroundStyle(.secondary)
            }

        case .connected:
            phase(symbol: "checkmark.circle.fill", title: "Connected",
                  detail: "You're paired with \(macStore.primary?.name ?? "your Mac").")
                .onAppear {
                    Haptics.success()
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        await advanceAfterConnect()
                    }
                }

        case .notifications:
            phase(symbol: "bell.badge", title: "Get notified",
                  detail: "DoomCoder can alert you when an agent on your Mac needs your attention — for example, when it's waiting for approval. No marketing, ever. This is optional.")
            VStack(spacing: 12) {
                Button("Enable Notifications") { Task { await requestNotifications() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Not Now") { finish() }
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func phase(symbol: String, title: String, detail: String, showSpinner: Bool = false) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if showSpinner { ProgressView().padding(.top, 4) }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Flow logic

    private func begin() async {
        step = .checkingiCloud
        let available = await isiCloudAvailable()
        guard available else { step = .icloudNeeded; return }
        step = .searching
        // After disconnect, the sync engine holds a stale incremental token that
        // causes fetchChanges() to return zero records (the Mac's MacStatus was
        // already "seen" before the disconnect). forceFetchAll() wipes the token
        // and re-initialises the engine, then awaits a full CloudKit re-fetch so
        // all current records (including the Mac heartbeat) arrive via the
        // delegate before this call returns.
        await CompanionSyncEngine.shared.forceFetchAll()
        // Fallback: if the Mac published its heartbeat after our initial import
        // window (e.g. just restarted), poll a couple more times.
        for _ in 0..<3 {
            if !macStore.byMacId.isEmpty { break }
            try? await Task.sleep(for: .seconds(2))
            await CompanionSyncEngine.shared.fetchChanges()
        }
        switch macStore.byMacId.count {
        case 0:
            step = .noMacs
        case 1:
            if let only = macStore.byMacId.values.first { select(only.macId) }
        default:
            step = .picker
        }
    }

    private func select(_ macId: String) {
        macStore.setPrimary(macId)
        step = .connected
    }

    private func advanceAfterConnect() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            step = .notifications
        } else {
            finish()
        }
    }

    private func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        finish()
    }

    private func isiCloudAvailable() async -> Bool {
        let status = try? await CKContainer(identifier: CloudKitConstants.containerIdentifier).accountStatus()
        return status == .available
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func finish() {
        onFinished()
        dismiss()
    }
}
