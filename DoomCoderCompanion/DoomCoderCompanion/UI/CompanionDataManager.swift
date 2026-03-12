// CompanionDataManager.swift — Doom Coder Companion
// Central, user-controlled data clearing for the Data & Privacy screen. Each
// granular method wipes one slice of on-device storage; `eraseEverything()`
// performs a full LOCAL reset so the app behaves like a brand-new install.
//
// Local-only by design: nothing here deletes your iCloud records. Re-pairing a
// Mac re-downloads its live data. The caller quits the app after a full erase.

import Foundation
import DoomCoderCore

@MainActor
enum CompanionDataManager {

    private static let aiKeyService = "com.doomcoder.app.companion.aikey"

    // MARK: - Granular clears

    /// Saved prompt drafts + AI refine chats (local-only).
    static func clearPromptsAndChats() {
        PromptStore.shared.deleteAll()
        ConversationStore.shared.deleteAll()
    }

    /// Freeform notes (local-only).
    static func clearNotes() {
        NotesStore.shared.deleteAll()
    }

    /// API keys (Keychain) + AI provider/model/mode preferences.
    static func clearAIKeysAndSettings() {
        let ai = AIEngineCoordinator.shared
        for provider in AIProvider.allCases { ai.clearKey(for: provider) }
        Keychain.deleteAll(service: aiKeyService)
        let d = UserDefaults.standard
        d.removeObject(forKey: "tools.ai.selection")
        d.removeObject(forKey: "tools.ai.provider")
        for provider in AIProvider.allCases {
            d.removeObject(forKey: "tools.ai.model.\(provider.rawValue)")
        }
        // Reflect the reset in the live coordinator.
        ai.selection = .appleOnDevice
        ai.provider = .openai
    }

    /// Cached agent lists, notification history and downloaded icons. This is a
    /// local mirror of iCloud and re-downloads for any still-paired Mac.
    static func clearCachedAgentData() {
        LocalStore.shared.wipeAll()
        NotificationLogStore.shared.clear()
        AgentListStore.shared.clear()
        AppGroupCache.clearIcons()
        AppGroupCache.defaults.removeObject(forKey: AppGroupCache.installedAgentsKey)
    }

    /// Disconnects every paired Mac: leaves shares, forgets cached status, and
    /// resets local sync state + this device's identity. iCloud and the Mac app
    /// are unaffected; you can reconnect any time.
    static func disconnectAllMacs() async {
        let macIds = Array(MacStatusStore.shared.byMacId.keys)
        for macId in macIds {
            await CompanionSyncEngine.shared.leaveShare(forMacId: macId)
        }
        MacStatusStore.shared.clear()
        AgentListStore.shared.clear()
        await CompanionSyncEngine.shared.resetLocalSyncState()
        Keychain.delete(account: CompanionSyncEngine.deviceIdAccount,
                        service: CompanionSyncEngine.deviceIdService)
    }

    // MARK: - Full reset

    /// Erases EVERYTHING — on-device data AND this device's CloudKit footprint —
    /// so the app behaves like a fresh install and won't re-sync old data back.
    /// The UI quits the app immediately after. See `eraseCloudKitData` for the
    /// cross-device implications (a still-running same-account Mac may republish).
    static func eraseEverything() async {
        // 1. iCloud teardown FIRST, while the sync engines + account are alive:
        //    deletes subscriptions and every reachable custom zone (this is what
        //    stops the connected device + agents/notifications coming back).
        await CompanionSyncEngine.shared.eraseCloudKitData()

        // 2. Local tool data (Application Support/DoomCoderTools).
        clearPromptsAndChats()
        clearNotes()
        // SQLite mirror.
        LocalStore.shared.wipeAll()
        // Keychain: API keys + this device's stable identity.
        Keychain.deleteAll(service: aiKeyService)
        Keychain.deleteAll(service: CompanionSyncEngine.deviceIdService)
        // All standard UserDefaults (AI prefs, welcome flag mirror, etc.).
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        // The entire App Group: every cache key + container files.
        AppGroupCache.eraseEverything()
    }
}
