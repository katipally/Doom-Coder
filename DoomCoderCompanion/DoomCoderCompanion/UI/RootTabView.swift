// RootTabView.swift — DoomCoder Companion (v3.1)
// 3 tabs: Home / Agents / Settings. The "Sessions" tab from v3.0 is
// retired — the per-session detail screen is reachable via Agents tab
// drill-in (see AgentsView in SessionsView.swift, which keeps that
// filename to avoid pbxproj surgery).

import SwiftUI

struct RootTabView: View {
    /// Set by CompanionApp when a `doomcoder://session/<key>` URL opens the app.
    /// Forwarded into AgentsView so it can push SessionDetailView automatically.
    @Binding var deeplinkSessionKey: String?

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                HomeView()
            }
            Tab("Agents", systemImage: "cpu") {
                AgentsView(deeplinkSessionKey: $deeplinkSessionKey)
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
    }
}
