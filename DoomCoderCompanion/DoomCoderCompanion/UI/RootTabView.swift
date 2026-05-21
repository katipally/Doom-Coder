// RootTabView.swift — DoomCoder Companion (v3.1)
// 3 tabs: Home / Agents / Settings. The "Sessions" tab from v3.0 is
// retired — the per-session detail screen is reachable via Agents tab
// drill-in (see AgentsView in SessionsView.swift, which keeps that
// filename to avoid pbxproj surgery).

import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                HomeView()
            }
            Tab("Agents", systemImage: "cpu") {
                AgentsView()
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
    }
}
