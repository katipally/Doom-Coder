// AIEngineCoordinator.swift — DoomCoderCore
// The single façade the UI talks to. Picks the right tier(s), runs the fallback
// policy, and owns the user's engine preference + provider/model selection.
//
// Fallback policy (per design critique):
//   • Automatic / On-device: try Apple on-device, then Built-in (heuristic).
//     NEVER sends content to a remote provider automatically (privacy-safe).
//   • My API key (explicit opt-in): try the provider; surface ACTIONABLE errors
//     (network/provider/rate-limit/missing-key) instead of silently degrading;
//     fall back to Built-in only for non-actionable failures (malformed/refusal).
//   • Built-in: heuristic only.

import Foundation
import Observation

/// User-facing engine preference.
public enum AIEngineSelection: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic
    case appleOnDevice
    case remoteKey
    case heuristic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic:     return "Automatic"
        case .appleOnDevice: return "On-device (Apple Intelligence)"
        case .remoteKey:     return "My API key"
        case .heuristic:     return "Built-in (offline)"
        }
    }

    public var detail: String {
        switch self {
        case .automatic:     return "On-device when available, otherwise built-in. Stays private."
        case .appleOnDevice: return "Apple's on-device model. Free, offline, private."
        case .remoteKey:     return "Your OpenAI/Anthropic key. Content is sent to the provider."
        case .heuristic:     return "Deterministic, no AI service. Works everywhere."
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
        let rawSel = UserDefaults.standard.string(forKey: selectionKey) ?? AIEngineSelection.automatic.rawValue
        selection = AIEngineSelection(rawValue: rawSel) ?? .automatic
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

    public func chat(question: String, context: [DocChunk]) async -> AIResult<DocAnswer> {
        await run { await $0.chat(question: question, context: context) }
    }

    // MARK: - Engine routing

    /// Ordered engines to try for the current selection. Built-in is always the
    /// last resort so every feature works standalone.
    private func engineChain() -> [any AIEngine] {
        let apple = AppleFoundationEngine()
        let heuristic = HeuristicEngine()
        switch selection {
        case .automatic, .appleOnDevice:
            return [apple, heuristic]
        case .heuristic:
            return [heuristic]
        case .remoteKey:
            if let remote = makeRemoteEngine() {
                return [remote, heuristic]
            }
            return [heuristic]
        }
    }

    private func makeRemoteEngine() -> RemoteKeyEngine? {
        guard let key = key(for: provider), !key.isEmpty else { return nil }
        return RemoteKeyEngine(provider: provider, model: selectedModel(for: provider), apiKey: key)
    }

    /// Runs `op` across the engine chain. Stops and surfaces the first ACTIONABLE
    /// failure (so users see real errors for their own key); otherwise falls
    /// through to the next engine. Returns the last failure if all fail.
    private func run<T: Sendable>(_ op: @Sendable (any AIEngine) async -> AIResult<T>) async -> AIResult<T> {
        let chain = engineChain()
        var lastFailure: AIResult<T>?
        for engine in chain {
            let result = await op(engine)
            switch result {
            case .success:
                return result
            case .failure(let failure, _):
                if failure.isActionable { return result }
                lastFailure = result
            }
        }
        return lastFailure ?? .failure(.unavailable(.unknown("No engine available")), tier: nil)
    }
}
