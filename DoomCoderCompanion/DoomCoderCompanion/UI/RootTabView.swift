// RootTabView.swift — DoomCoder Companion
// Single NavigationStack rooted on AgentListView (v1: no TabView)

import SwiftUI

struct RootTabView: View {
    var body: some View {
        NavigationStack {
            AgentListView()
        }
    }
}
