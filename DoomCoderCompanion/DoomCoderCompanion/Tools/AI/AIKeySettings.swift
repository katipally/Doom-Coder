// AIKeySettings.swift — DoomCoder Companion (Tools)
// Observable settings for the optional Smart-enhance feature: selected provider
// and whether a key is present. The key itself lives in the Keychain; this store
// exposes only presence + provider selection to the UI.

import Foundation
import Observation

@MainActor
@Observable
final class AIKeySettings {
    static let shared = AIKeySettings()

    private let providerKey = "tools.ai.provider"

    var provider: AIProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: providerKey) }
    }

    /// Bumped on key changes so views observing this object re-render.
    private(set) var keyRevision: Int = 0

    private init() {
        let raw = UserDefaults.standard.string(forKey: providerKey) ?? AIProvider.openai.rawValue
        provider = AIProvider(rawValue: raw) ?? .openai
    }

    private func account(for provider: AIProvider) -> String { "key.\(provider.rawValue)" }

    func key(for provider: AIProvider) -> String? {
        Keychain.get(account: account(for: provider))
    }

    func hasKey(for provider: AIProvider) -> Bool {
        (key(for: provider)?.isEmpty == false)
    }

    var hasKeyForCurrentProvider: Bool { hasKey(for: provider) }

    func setKey(_ value: String, for provider: AIProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(account: account(for: provider))
        } else {
            Keychain.set(trimmed, account: account(for: provider))
        }
        keyRevision += 1
    }

    func clearKey(for provider: AIProvider) {
        Keychain.delete(account: account(for: provider))
        keyRevision += 1
    }
}
