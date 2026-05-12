import Foundation

enum FeatureFlags {
    private static let cloudKitKey = "FeatureFlags.cloudKitEnabled"
    private static let minimalModeKey = "FeatureFlags.minimalMode"
    private static let joinBetaKey = "FeatureFlags.joinBetaChannel"

    static var cloudKitEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: cloudKitKey) }
        set { UserDefaults.standard.set(newValue, forKey: cloudKitKey) }
    }

    static var minimalMode: Bool {
        get { UserDefaults.standard.bool(forKey: minimalModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: minimalModeKey) }
    }

    /// When true, Sparkle's updater allows items tagged with `<sparkle:channel>beta</sparkle:channel>`.
    static var joinBetaChannel: Bool {
        get { UserDefaults.standard.bool(forKey: joinBetaKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: joinBetaKey)
            // Notify the updater controller to re-evaluate allowed channels.
            NotificationCenter.default.post(name: .betaChannelDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    static let betaChannelDidChange = Notification.Name("com.doomcoder.betaChannelDidChange")
}
