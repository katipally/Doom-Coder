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
        }
    }
}
