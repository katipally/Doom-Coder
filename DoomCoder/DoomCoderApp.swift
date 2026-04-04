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

        Window("About Doom Coder", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

