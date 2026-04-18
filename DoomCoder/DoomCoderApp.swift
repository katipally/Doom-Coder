import SwiftUI

@main
struct DoomCoderApp: App {
    @State private var sleepManager = SleepManager()
    @State private var updaterViewModel = CheckForUpdatesViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                sleepManager: sleepManager,
                updaterViewModel: updaterViewModel
            )
        } label: {
            Image(systemName: sleepManager.isActive ? "bolt.fill" : "bolt.slash.fill")
                .symbolRenderingMode(.monochrome)
        }

        Window("Settings", id: "settings") {
            SettingsView(sleepManager: sleepManager)
        }
        .windowResizability(.contentSize)

        Window("About Doom Coder", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}
