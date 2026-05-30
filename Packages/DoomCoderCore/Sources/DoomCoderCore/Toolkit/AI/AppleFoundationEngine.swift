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

public struct AppleFoundationEngine: AIEngine {
    public nonisolated let tier: AITier = .appleOnDevice

    public init() {}

    public func probe() async -> AIFailure? {
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
    }

    // MARK: Enhance

    public func enhance(_ raw: String) async -> AIResult<String> {
        let idea = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty else { return .failure(.malformed, tier: tier) }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            if let f = await probe() { return .failure(f, tier: tier) }
            let instructions = """
            You are an expert prompt engineer for AI coding agents. Rewrite the user's \
            rough request into a single, clear, well-structured prompt that preserves \
            their intent. Add concise sections for context, requirements, and expected \
            output where helpful. Do NOT solve the request — only return the improved \
            prompt text, with no preamble or code fences.
            """
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: idea)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
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
    }
}
