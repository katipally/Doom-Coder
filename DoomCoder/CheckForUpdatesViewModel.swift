import Foundation
import Sparkle

/// Opts DoomCoder's MenuBarExtra into Sparkle's "gentle reminder" update
/// prompting. Without this, Sparkle logs a warning every launch because
/// background/menu-bar apps otherwise miss update alerts. We keep it dead
/// simple — tell Sparkle we support gentle reminders and let its standard
/// user driver handle the UI.
@MainActor
final class SparkleUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}

/// Wraps Sparkle's updater controller for SwiftUI observation.
@Observable
@MainActor
final class CheckForUpdatesViewModel {
    private(set) var canCheckForUpdates = false

    @ObservationIgnored
    let updaterController: SPUStandardUpdaterController

    @ObservationIgnored
    private let driverDelegate = SparkleUserDriverDelegate()

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: driverDelegate
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
