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

/// Delegates Sparkle channel filtering to `FeatureFlags.joinBetaChannel`.
/// Items tagged `<sparkle:channel>beta</sparkle:channel>` are only shown
/// when the user has opted in; stable items (no channel tag) are always shown.
final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        FeatureFlags.joinBetaChannel ? ["beta"] : []
    }
}

/// Wraps Sparkle's updater controller for SwiftUI observation.
@Observable
@MainActor
final class CheckForUpdatesViewModel {
    static let shared = CheckForUpdatesViewModel()

    private(set) var canCheckForUpdates = false

    @ObservationIgnored
    let updaterController: SPUStandardUpdaterController

    @ObservationIgnored
    private let driverDelegate = SparkleUserDriverDelegate()

    @ObservationIgnored
    private let updaterDelegate = SparkleUpdaterDelegate()

    @ObservationIgnored
    private var cancellable: AnyCancellable?

    @ObservationIgnored
    private var betaObserver: NSObjectProtocol?

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: driverDelegate
        )
        // Observe canCheckForUpdates via KVO so the button re-enables
        // automatically after Sparkle finishes its check.
        cancellable = updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                Task { @MainActor [weak self] in
                    self?.canCheckForUpdates = value
                }
            }
        // Trigger a new check when beta preference changes so the user
        // immediately sees beta items if they just opted in.
        betaObserver = NotificationCenter.default.addObserver(
            forName: .betaChannelDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.canCheckForUpdates else { return }
                self.updaterController.updater.checkForUpdates()
            }
        }
    }

    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }
}
