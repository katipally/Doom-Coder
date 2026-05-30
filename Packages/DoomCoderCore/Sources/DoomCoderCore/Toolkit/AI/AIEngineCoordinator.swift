// AIEngineCoordinator.swift — DoomCoderCore
// The single façade the UI talks to. Owns the user's engine preference +
// provider/model selection and runs the selected backend.
//
// Policy:
//   • On-device: run Apple FoundationModels; surface the real availability/error.
//   • My API key (explicit opt-in): run the provider; surface ACTIONABLE errors
//     (network/provider/rate-limit/missing-key) directly.
// There is no silent fallback — the user sees exactly which engine answered and
// why it failed. Manual authoring + Notes always work with no AI.

import Foundation
import Observation

/// User-facing engine preference.
public enum AIEngineSelection: String, Codable, CaseIterable, Sendable, Identifiable {
    case appleOnDevice
    case remoteKey

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleOnDevice: return "On-device"
        case .remoteKey:     return "My API key"
        }
    }

    public var detail: String {
        switch self {
        case .appleOnDevice: return "Apple's on-device model. Free, offline, private."
        case .remoteKey:     return "Your OpenAI/Anthropic key. Content is sent to the provider."
        }
    }
}

@MainActor
@Observable
public final class AIEngineCoordinator {
    public static let shared = AIEngineCoordinator()

    private let selectionKey = "tools.ai.selection"
    private let providerKey = "tools.ai.provider"
    private func modelKey(_ p: AIProvider) -> String { "tools.ai.model.\(p.rawValue)" }
    private func account(_ p: AIProvider) -> String { "key.\(p.rawValue)" }

    public var selection: AIEngineSelection {
        didSet { UserDefaults.standard.set(selection.rawValue, forKey: selectionKey) }
    }

    public var provider: AIProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: providerKey) }
    }

    /// Bumped whenever a key or model changes, so observing views re-render.
    public private(set) var revision: Int = 0

    /// Models discovered by the last successful "Test key", per provider.
    public private(set) var discoveredModels: [AIProvider: [String]] = [:]

    private init() {
        let rawSel = UserDefaults.standard.string(forKey: selectionKey) ?? AIEngineSelection.appleOnDevice.rawValue
        selection = AIEngineSelection(rawValue: rawSel) ?? .appleOnDevice
        let rawProv = UserDefaults.standard.string(forKey: providerKey) ?? AIProvider.openai.rawValue
        provider = AIProvider(rawValue: rawProv) ?? .openai
    }

    // MARK: - Key management

    public func key(for provider: AIProvider) -> String? { Keychain.get(account: account(provider)) }
    public func hasKey(for provider: AIProvider) -> Bool { key(for: provider)?.isEmpty == false }
    public var hasKeyForCurrentProvider: Bool { hasKey(for: provider) }

    public func setKey(_ value: String, for provider: AIProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(account: account(provider)) }
        else { Keychain.set(trimmed, account: account(provider)) }
        revision += 1
    }

    public func clearKey(for provider: AIProvider) {
        Keychain.delete(account: account(provider))
        revision += 1
    }

    // MARK: - Model selection

    public func selectedModel(for provider: AIProvider) -> String {
        UserDefaults.standard.string(forKey: modelKey(provider)) ?? provider.defaultModel
    }

    public func setSelectedModel(_ model: String, for provider: AIProvider) {
        UserDefaults.standard.set(model, forKey: modelKey(provider))
        revision += 1
    }

    /// Validates a key and populates the model picker for the provider.
    public func testKey(for provider: AIProvider) async -> Result<[String], AIFailure> {
        guard let key = key(for: provider), !key.isEmpty else { return .failure(.missingKey) }
        let result = await RemoteKeyEngine.listModels(provider: provider, apiKey: key)
        switch result {
        case .success(let models):
            let ids = models.map(\.id)
            discoveredModels[provider] = ids
            // Auto-pick a sensible default if the saved one isn't offered.
            if !ids.contains(selectedModel(for: provider)), let first = ids.first {
                setSelectedModel(first, for: provider)
            }
            revision += 1
            return .success(ids)
        case .failure(let f):
            return .failure(f)
        }
    }

    // MARK: - Availability

    /// `nil` when on-device AI can run; otherwise the reason it can't.
    public func appleAvailability() async -> AIFailure? {
        await AppleFoundationEngine().probe()
    }

    // MARK: - Capabilities (with fallback policy)

    public func enhance(_ raw: String) async -> AIResult<String> {
        await run { await $0.enhance(raw) }
    }

    public func compose(intent: String) async -> AIResult<ComposedTemplate> {
        await run { await $0.compose(intent: intent) }
    }

    // MARK: - Engine routing

    /// The engine(s) to run for the current selection. There is no silent
    /// fallback — each selection maps to exactly one backend so users always
    /// know which engine answered.
    private func engineChain() -> [any AIEngine] {
        switch selection {
        case .appleOnDevice:
            return [AppleFoundationEngine()]
        case .remoteKey:
            // Always construct the remote engine (even with an empty key) so its
            // methods surface an actionable `.missingKey` instead of a vague error.
            return [RemoteKeyEngine(provider: provider, model: selectedModel(for: provider), apiKey: key(for: provider) ?? "")]
        }
    }

    /// Runs `op` on the selected engine and returns its result directly. With a
    /// single engine per selection there is no fallthrough; the engine's own
    /// success/failure (including actionable errors) is surfaced to the UI.
    private func run<T: Sendable>(_ op: @Sendable (any AIEngine) async -> AIResult<T>) async -> AIResult<T> {
        guard let engine = engineChain().first else {
            return .failure(.unavailable(.unknown("No engine available")), tier: nil)
        }
        return await op(engine)
    }
}
