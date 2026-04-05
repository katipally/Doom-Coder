import SwiftUI
import ServiceManagement

@main
struct DoomCoderApp: App {
    @State private var sleepManager = SleepManager()
    @State private var updaterViewModel = CheckForUpdatesViewModel()
    @State private var appDetector = AppDetector()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                sleepManager: sleepManager,
                updaterViewModel: updaterViewModel,
                appDetector: appDetector
            )
        } label: {
            Image(systemName: sleepManager.isActive ? "bolt.fill" : "bolt.slash.fill")
                .symbolRenderingMode(.monochrome)
        }

        Window("Active Apps", id: "active-apps") {
            ActiveAppsView(appDetector: appDetector, sleepManager: sleepManager)
        }
        .windowResizability(.contentSize)

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

