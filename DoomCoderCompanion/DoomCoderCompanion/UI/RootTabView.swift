// RootTabView.swift — DoomCoder Companion
// Three-tab structure (Home / Agents / Settings). Each tab is a standalone
// NavigationStack so the app is fully usable with no Mac, no iCloud, and no
// notifications — the standalone-functionality requirement (App Store 4.2.3).
// On iOS 26 the tab bar renders with the system Liquid Glass material.

import SwiftUI

struct RootTabView: View {
    /// First-run welcome is informational and dismissible — it never blocks use.
    @State private var showWelcome: Bool = {
        AppGroupCache.defaults.object(forKey: WelcomeView.shownKey) == nil
    }()

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                NavigationStack { HomeView() }
            }
            Tab("Agents", systemImage: "square.stack.3d.up.fill") {
                NavigationStack { AgentListView() }
            }
            Tab("Settings", systemImage: "gearshape") {
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
