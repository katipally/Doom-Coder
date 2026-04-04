import SwiftUI

struct MenuBarView: View {
    var sleepManager: SleepManager
    var updaterViewModel: CheckForUpdatesViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            sleepManager.toggle()
        } label: {
            HStack {
                Image(systemName: sleepManager.isActive ? "bolt.fill" : "bolt.slash.fill")
                Text(sleepManager.isActive ? "Disable Doom Coder" : "Enable Doom Coder")
            }
        }

        if sleepManager.isActive, !sleepManager.elapsedTimeString.isEmpty {
            Text(sleepManager.elapsedTimeString)
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Check for Updates...") {
            updaterViewModel.checkForUpdates()
        }
        .disabled(!updaterViewModel.canCheckForUpdates)

        Button("About Doom Coder...") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "about")
        }

        Divider()

        Button("Quit Doom Coder") {
            sleepManager.disable()
            NSApplication.shared.terminate(nil)
        }
    }
}
