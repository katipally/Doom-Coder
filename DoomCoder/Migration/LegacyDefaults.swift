import Foundation

// Wipes UserDefaults keys owned by removed subsystems and migrates enabled
// flags across channel renames. Idempotent — each migration version runs at
// most once. Silent; logs a single stderr line per migration for support.
enum LegacyDefaults {
    private static let v10FlagKey = "doomcoder.migration.v1.0"
    private static let v11FlagKey = "doomcoder.migration.v1.1"
    private static let v12FlagKey = "doomcoder.migration.v1.2"
    private static let v18FlagKey = "doomcoder.migration.v1.8"

    private static let legacyKeys: [String] = [
        "doomcoder.customCLIBinaries",
        "doomcoder.customGUIBundles",
    ]

    private static let legacyKeyPrefixes: [String] = [
        "doomcoder.detectedApps.",
    ]

    static func migrate() {
        migrateV10()
        migrateV11()
        migrateV12()
        migrateV18()
    }

    private static func migrateV10() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: v10FlagKey) else { return }

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

        defaults.set(true, forKey: v10FlagKey)
        FileHandle.standardError.write(Data("LegacyDefaults v1.0: migrated \(removed) keys\n".utf8))
    }

    // v1.0 → v1.1:
    //   - `doomcoder.iphone.reminder.enabled`  → `doomcoder.iphone.calendar.enabled`
    //   - `doomcoder.iphone.imessage.enabled`  → force off (Apple blocks iMessage-to-self)
    //   - `doomcoder.focus.enabled`            → removed (Focus Filter integration dropped)
    // Keys in IPhoneRelay.Keys still READ the legacy names lazily; this
    // migration flips the new canonical key so the UI reflects the right
    // state on first launch.
    private static func migrateV11() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: v11FlagKey) else { return }

        var migrated = 0

        // Carry reminder-enabled forward as calendar-enabled (user was already
        // opted into iCloud delivery; give them the replacement channel on by
        // default).
        if defaults.object(forKey: "doomcoder.iphone.reminder.enabled") != nil {
            let wasEnabled = defaults.bool(forKey: "doomcoder.iphone.reminder.enabled")
            defaults.set(wasEnabled, forKey: "doomcoder.iphone.calendar.enabled")
            migrated += 1
        }

        // Hard-disable iMessage — it never worked to self anyway.
        if defaults.object(forKey: "doomcoder.iphone.imessage.enabled") != nil {
            defaults.set(false, forKey: "doomcoder.iphone.imessage.enabled")
            migrated += 1
        }

        // Wipe Focus state entirely.
        for key in ["doomcoder.focus.enabled", "doomcoder.focus.lastDonationAt", "doomcoder.focus.lastActive"] {
            if defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
                migrated += 1
            }
        }

        defaults.set(true, forKey: v11FlagKey)
        FileHandle.standardError.write(Data("LegacyDefaults v1.1: migrated \(migrated) keys\n".utf8))
    }

    // v1.1 → v1.2:
    //   - Calendar channel removed entirely — alarms never reliably propagated.
    //   - Per-channel `isEnabled` flag replaced with a single `selectedChannelID`
    //     ("pick one active delivery method"). Legacy enabled flags are cleared.
    //   - If the user had ntfy (or calendar) enabled, migrate them to the ntfy
    //     channel as active so delivery doesn't silently stop.
    private static func migrateV12() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: v12FlagKey) else { return }

        var migrated = 0
        let calendarWasEnabled = defaults.bool(forKey: IPhoneRelay.Keys.legacyCalendarEnabled)
        let ntfyWasEnabled     = defaults.bool(forKey: IPhoneRelay.Keys.legacyNtfyEnabled)
        let ntfyTopic          = (defaults.string(forKey: IPhoneRelay.Keys.ntfyTopic) ?? "")
            .trimmingCharacters(in: .whitespaces)

        // Clear the removed enable flags.
        for key in [
            IPhoneRelay.Keys.legacyCalendarEnabled,
            IPhoneRelay.Keys.legacyNtfyEnabled
        ] {
            if defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
                migrated += 1
            }
        }

        // Pre-select ntfy for users who had any iPhone delivery turned on and
        // have a topic configured — otherwise leave unset so the picker's
        // auto-pick kicks in.
        if (calendarWasEnabled || ntfyWasEnabled) && !ntfyTopic.isEmpty {
            defaults.set("ntfy", forKey: IPhoneRelay.Keys.selectedChannelID)
            migrated += 1
        }

        defaults.set(true, forKey: v12FlagKey)
        FileHandle.standardError.write(Data("LegacyDefaults v1.2: migrated \(migrated) keys\n".utf8))
    }

    // v1.2 → v1.8:
    //   - WatchTarget enum (.none/.all/.agentType) replaced with a per-agent
    //     Set<String> at `dc.watchedAgentIds`. Legacy `.all` → seed every
    //     currently-configured agent. `.agentType(id)` → just {id}. `.none`
    //     → empty set.
    //   - Transport mode `"full"` → `"screenOn"` at `doomcoder.mode`.
    //   - Legacy hook round-trip flag cleared.
    private static func migrateV18() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: v18FlagKey) else { return }

        var migrated = 0

        // Mode rename
        if defaults.string(forKey: "doomcoder.mode") == "full" {
            defaults.set("screenOn", forKey: "doomcoder.mode")
            migrated += 1
        }

        // WatchTarget → watchedAgentIds
        if defaults.array(forKey: "dc.watchedAgentIds") == nil,
           let data = defaults.data(forKey: "dc.watchTarget") {
            // Minimal manual decode — WatchTarget no longer exists as a type.
            // The encoded JSON looks like {"none":{}} / {"all":{}} /
            // {"agentType":{"_0":"cursor"}}.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if obj["all"] != nil {
                    let configured = (defaults.array(forKey: "dc.configuredAgentIds") as? [String]) ?? []
                    defaults.set(configured, forKey: "dc.watchedAgentIds")
                } else if let at = obj["agentType"] as? [String: Any],
                          let id = at["_0"] as? String {
                    defaults.set([id], forKey: "dc.watchedAgentIds")
                } else {
                    defaults.set([String](), forKey: "dc.watchedAgentIds")
                }
                migrated += 1
            }
            defaults.removeObject(forKey: "dc.watchTarget")
        }

        // Drop legacy hook round-trip dict
        if defaults.object(forKey: "dc.didRoundTrip") != nil {
            defaults.removeObject(forKey: "dc.didRoundTrip")
            migrated += 1
        }

        defaults.set(true, forKey: v18FlagKey)
        FileHandle.standardError.write(Data("LegacyDefaults v1.8: migrated \(migrated) keys\n".utf8))
    }
}
