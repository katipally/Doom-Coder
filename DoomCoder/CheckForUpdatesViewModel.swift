import Foundation
import Sparkle

/// Wraps Sparkle's updater controller for SwiftUI observation.
@Observable
@MainActor
final class CheckForUpdatesViewModel {
    private(set) var canCheckForUpdates = false

    @ObservationIgnored
    let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Poll canCheckForUpdates on a short delay after startup
        Task {
            try? await Task.sleep(for: .seconds(1))
            self.canCheckForUpdates = self.updaterController.updater.canCheckForUpdates
        }
    }

    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
        canCheckForUpdates = updaterController.updater.canCheckForUpdates
    }
}
