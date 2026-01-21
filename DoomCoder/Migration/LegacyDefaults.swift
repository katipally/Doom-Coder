import Foundation

// Wipes UserDefaults keys owned by v0.x heuristic tracking so a fresh v1.0
// install starts clean. Runs exactly once per install — subsequent launches
// are a no-op. Silent; logs a single stderr line for support.
enum LegacyDefaults {
    private static let migrationFlagKey = "doomcoder.migration.v1.0"

    private static let legacyKeys: [String] = [
        "doomcoder.customCLIBinaries",
        "doomcoder.customGUIBundles",
    ]

    private static let legacyKeyPrefixes: [String] = [
        "doomcoder.detectedApps.",
    ]

    static func migrate() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationFlagKey) else { return }

        var removed = 0
        for key in legacyKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            removed += 1
        }
        for (key, _) in defaults.dictionaryRepresentation() {
            if legacyKeyPrefixes.contains(where: { key.hasPrefix($0) }) {
                defaults.removeObject(forKey: key)
                removed += 1
            }
        }

        defaults.set(true, forKey: migrationFlagKey)
        FileHandle.standardError.write(Data("LegacyDefaults: migrated \(removed) keys\n".utf8))
    }
}
