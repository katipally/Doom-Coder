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
    /// `@Generable` schema already enforces "return only the prompt." The wording
    /// is emphatic that the input is a REQUEST TO REWRITE — never a question to
    /// answer — which is the single most common on-device failure mode.
    static let instructions = """
    You are a prompt engineer for AI coding agents (Claude Code, Codex, Copilot \
    CLI, etc.). Your ONLY job is to rewrite the user's text into one clear, \
    well-structured PROMPT they can paste into a coding agent.

    The user's text is ALWAYS a rough request to be rewritten — NEVER a question \
    for you to answer and NEVER a task for you to perform. Do not solve it, do \
    not write code, do not explain, do not add preamble or commentary or code \
    fences. Return only the improved prompt.

    Preserve the user's intent. Briefly state context, the concrete task, and the \
    expected output. Keep it tight — no filler. When the conversation already \
    contains a refined prompt and a new instruction, apply that instruction to \
    the existing prompt and return the full updated prompt.

    Example (format only — never reference or reuse this content):
    Rough request: "add dark mode"
    Improved prompt: "Add a dark mode option. Implement a theme system that \
    switches between light and dark palettes, persist the user's choice, and \
    default to the system appearance. Expected output: the code changes needed \
    across the UI and settings."
    """

    /// Builds a single prompt string from a transcript. A lone user turn is sent
    /// verbatim (the instructions carry the rewrite directive). A multi-turn
    /// transcript is rendered as labeled turns so the model applies the latest
    /// instruction to the existing refined prompt.
    static func composePrompt(from transcript: [AIChatTurn]) -> String {
        let userTurns = transcript.filter { $0.role == .user }
        guard transcript.count > 1, userTurns.count > 1 || transcript.contains(where: { $0.role == .assistant }) else {
            return transcript.last(where: { $0.role == .user })?.text
                ?? transcript.last?.text ?? ""
        }
        var lines: [String] = ["Refine the prompt below. Apply the final instruction and return the full updated prompt only.\n"]
        var seenFirstUser = false
        for turn in transcript {
            switch turn.role {
            case .user:
                if !seenFirstUser {
                    lines.append("Original request:\n\(turn.text)")
                    seenFirstUser = true
                } else {
                    lines.append("Refinement instruction:\n\(turn.text)")
                }
            case .assistant:
                lines.append("Current refined prompt:\n\(turn.text)")
            }
        }
        return lines.joined(separator: "\n\n")
    }

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

    // MARK: Stream

    public func stream(transcript: [AIChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let prompt = Self.composePrompt(from: transcript)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prompt.isEmpty else {
                    continuation.finish(throwing: AIFailure.malformed)
                    return
                }
                #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                    if let failure = await probe() {
                        continuation.finish(throwing: failure)
                        return
                    }
                    do {
                        let session = LanguageModelSession(instructions: Self.instructions)
                        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 1200)
                        let responseStream = session.streamResponse(
                            to: prompt,
                            generating: EnhancedPrompt.self,
                            options: options
                        )
                        for try await snapshot in responseStream {
                            if Task.isCancelled { break }
                            if let partial = snapshot.content.prompt {
                                continuation.yield(partial)
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: Self.mapError(error))
                    }
                    return
                }
                #endif
                continuation.finish(throwing: AIFailure.unavailable(.platformUnsupported))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
