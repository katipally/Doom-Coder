// RootTabView.swift — DoomCoder Companion
// Top-level tab container. iOS 26 gives Liquid Glass chrome for free;
// we just declare the tabs and let the system render them.

import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                HomeView()
            }
            Tab("Sessions", systemImage: "waveform.path") {
                SessionsView()
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
    }
}
