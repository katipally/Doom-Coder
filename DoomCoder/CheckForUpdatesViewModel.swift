import Foundation
import Combine
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

    @ObservationIgnored
    private var cancellable: AnyCancellable?

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: driverDelegate
        )
        // Observe canCheckForUpdates via KVO so the button re-enables
        // automatically after Sparkle finishes its check.
        cancellable = updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
    }

    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }
}
