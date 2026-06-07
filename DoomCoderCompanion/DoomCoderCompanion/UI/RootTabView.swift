// RootTabView.swift — DoomCoder Companion
// Four-tab structure (Prompts / Notes / Dashboard / Settings), launching on
// Prompts. Prompts and Notes are 100% standalone — they work with no Mac, no
// account, and no internet (App Store 4.2.3 standalone functionality).
// Dashboard adds live Mac monitoring when connected.
// On iOS 26 the tab bar renders with the system Liquid Glass material.

import SwiftUI
import DoomCoderCore

struct RootTabView: View {
    @State private var router = AppRouter.shared
    /// First-run welcome is informational and dismissible — it never blocks use.
    @State private var showWelcome: Bool = {
        AppGroupCache.defaults.object(forKey: WelcomeView.shownKey) == nil
    }()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $router.selectedTab) {
            Tab("Prompts", systemImage: "text.alignleft", value: RootTab.prompts) {
                NavigationStack { PromptsView() }
            }
            Tab("Notes", systemImage: "note.text", value: RootTab.notes) {
                NavigationStack { NotesView() }
            }
            Tab("Dashboard", systemImage: "macbook.and.iphone", value: RootTab.dashboard) {
                NavigationStack(path: $router.agentPath) {
                    DashboardView()
                        .navigationDestination(for: TrackedAgent.self) { agent in
                            AgentLogsView(agent: agent, macId: MacStatusStore.shared.primary?.macId)
                        }
                }
            }
            Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                NavigationStack { SettingsView() }
            }
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeView {
                AppGroupCache.defaults.set(Date(), forKey: WelcomeView.shownKey)
                showWelcome = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        // iPad sidebar layout: on regular width the tab bar collapses to
        // a macOS-style sidebar with the four tabs as a section. iPhone
        // keeps the bottom tab bar.
        .tabViewStyle(.sidebarAdaptable)
        // Audit 2026-06: allow SettingsView to re-trigger the welcome
        // sheet via `AppRouter.showWelcome()`. We observe the router's
        // `welcomeRequestCount` and flip `showWelcome` to true. We do
        // NOT clear the UserDefaults flag here so the user can re-show
        // it any number of times.
        .onChange(of: router.welcomeRequestCount) { _, _ in
            showWelcome = true
        }
        .task {
            // Cold-launch check: surface a non-blocking hint on Dashboard if the
            // user previously denied notifications. We never re-prompt the iOS
            // dialog (Apple disallows it) — the banner deep-links to Settings.
            await refreshNotificationHint()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // When the user returns from System Settings, re-check and hide
            // the banner if they re-enabled notifications.
            if newPhase == .active {
                Task { await refreshNotificationHint() }
            }
        }
    }

    private func refreshNotificationHint() async {
        let denied = await NotificationPermissionCenter.isDenied()
        router.showsNotificationDeniedHint = denied
    }
}
