import SwiftUI
import ServiceManagement

@main
struct DoomCoderApp: App {
    @State private var sleepManager = SleepManager()
    @State private var updaterViewModel = CheckForUpdatesViewModel()

    init() {
        if SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(sleepManager: sleepManager, updaterViewModel: updaterViewModel)
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
