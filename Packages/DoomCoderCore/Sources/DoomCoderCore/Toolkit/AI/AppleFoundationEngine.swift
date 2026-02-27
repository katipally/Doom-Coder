// AppleFoundationEngine.swift — DoomCoderCore
// Apple FoundationModels on-device engine. Free, offline, private, no account.
// Fully gated: compiles only where the framework exists, runs only on iOS 26 /
// macOS 26 with an eligible device that has Apple Intelligence ready. Never
// crashes when unavailable — returns a precise `.unavailable(reason)` so the UI
// can show actionable guidance.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
/// Structured result the on-device model must return. Constraining generation to
/// this schema (instead of free-form text) guarantees the model returns ONLY the
/// improved prompt — no preamble, apologies, or code fences leaking into the UI.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct EnhancedPrompt {
    @Guide(description: "The single, improved, ready-to-paste prompt. No preamble, commentary, or code fences.")
    var prompt: String
}
#endif

public struct AppleFoundationEngine: AIEngine {
    public nonisolated let tier: AITier = .appleOnDevice

    public init() {}

    /// Concise system prompt. Short on purpose: the on-device model follows tight,
    /// imperative instructions far more reliably than long prose, and the
    /// `@Generable` schema already enforces "return only the prompt."
    static let instructions = """
    You are a prompt engineer for AI coding agents. Rewrite the user's rough \
    request into one clear, well-structured prompt that preserves their intent. \
    Briefly state context, the concrete task, and the expected output. Keep it \
    tight — no filler. Do not answer or solve the request; return only the \
    improved prompt.
    """

    public func probe() async -> AIFailure? {
        #if targetEnvironment(simulator)
        // FoundationModels has no model assets in the iOS Simulator — generation
        // always fails there. Be honest up front instead of failing mid-request.
        return .unavailable(.simulatorUnsupported)
        #else
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                return .unavailable(Self.map(reason))
            }
        }
        #endif
        return .unavailable(.platformUnsupported)
        #endif
    }

    // MARK: Enhance

    public func enhance(_ raw: String) async -> AIResult<String> {
        let idea = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty else { return .failure(.malformed, tier: tier) }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            if let f = await probe() { return .failure(f, tier: tier) }
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                // Low temperature → deterministic, faithful rewriting rather than
                // creative drift. Bounded tokens keep latency + memory predictable.
                let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 1200)
                let response = try await session.respond(
                    to: idea,
                    generating: EnhancedPrompt.self,
                    options: options
                )
                let text = response.content.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? .failure(.malformed, tier: tier) : .success(text, tier: tier)
            } catch {
                return .failure(Self.mapError(error), tier: tier)
            }
        }
        #endif
        return .failure(.unavailable(.platformUnsupported), tier: tier)
    }

    // MARK: - Error mapping

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    static func map(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> AIUnavailableReason {
        switch reason {
        case .deviceNotEligible:            return .deviceNotEligible
        case .appleIntelligenceNotEnabled:  return .appleIntelligenceNotEnabled
        case .modelNotReady:                return .modelNotReady
        @unknown default:                   return .unknown("")
        }
    }
    #endif

    static func mapError(_ error: Error) -> AIFailure {
        if error is CancellationError { return .cancelled }
        #if targetEnvironment(simulator)
        return .unavailable(.simulatorUnsupported)
        #else
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            if let gen = error as? LanguageModelSession.GenerationError {
                switch gen {
                case .guardrailViolation:        return .safetyRefusal
                case .unsupportedLanguageOrLocale: return .safetyRefusal
                case .rateLimited:               return .rateLimited
                default:                         return .malformed
                }
            }
        }
        #endif
        return .malformed
        #endif
    }
}
