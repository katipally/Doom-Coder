import SwiftUI

struct RootTabView: View {
    @EnvironmentObject var store: SessionStore
    @State private var selection: Tab = .live

    enum Tab: Hashable { case live, history, settings }

    var body: some View {
        TabView(selection: $selection) {
            LiveTab()
                .tabItem { Label("Live", systemImage: "dot.radiowaves.left.and.right") }
                .tag(Tab.live)
            HistoryTab()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(.orange)
        .onChange(of: store.focusedSessionKey) { _, key in
            if key != nil { selection = .live }
        }
    }
}
