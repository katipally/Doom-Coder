import Foundation

enum FeatureFlags {
    private static let cloudKitKey = "FeatureFlags.cloudKitEnabled"
    private static let minimalModeKey = "FeatureFlags.minimalMode"

    static var cloudKitEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: cloudKitKey) }
        set { UserDefaults.standard.set(newValue, forKey: cloudKitKey) }
    }

    static var minimalMode: Bool {
        get { UserDefaults.standard.bool(forKey: minimalModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: minimalModeKey) }
    }
}
