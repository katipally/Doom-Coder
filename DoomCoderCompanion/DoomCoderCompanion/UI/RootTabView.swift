// RootTabView.swift — DoomCoder Companion
// Three-tab structure (Tools / Dashboard / Settings), launching on Tools. The
// Tools tab is 100% standalone — prompts, CLI reference, tasks and notes work
// with no Mac, no iCloud, and no notifications (App Store 4.2.3 standalone
// functionality). Dashboard adds live Mac monitoring when connected.
// On iOS 26 the tab bar renders with the system Liquid Glass material.

import SwiftUI

struct RootTabView: View {
    /// First-run welcome is informational and dismissible — it never blocks use.
    @State private var showWelcome: Bool = {
        AppGroupCache.defaults.object(forKey: WelcomeView.shownKey) == nil
    }()

    var body: some View {
        TabView {
            Tab("Tools", systemImage: "wrench.and.screwdriver") {
                NavigationStack { ToolsView() }
            }
            Tab("Dashboard", systemImage: "macbook.and.iphone") {
                NavigationStack { DashboardView() }
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
