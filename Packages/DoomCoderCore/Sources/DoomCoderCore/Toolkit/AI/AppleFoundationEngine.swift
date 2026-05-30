// AppleFoundationEngine.swift — DoomCoderCore
// Tier 1: Apple FoundationModels on-device engine. Free, offline, private, no
// account. Fully gated: compiles only where the framework exists, runs only on
// iOS 26 / macOS 26 with an eligible device that has Apple Intelligence ready.
// Never crashes when unavailable — returns a precise `.unavailable(reason)` so
// the coordinator can fall back to the heuristic tier.

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

    // MARK: Compose

    public func compose(intent: String) async -> AIResult<ComposedTemplate> {
        let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.malformed, tier: tier) }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            if let f = await probe() { return .failure(f, tier: tier) }
            let categories = PromptCategory.allCases.map(\.rawValue).joined(separator: ", ")
            let instructions = """
            You build REUSABLE prompt templates for AI coding agents. Given a user's \
            intent, produce a template whose body uses {{snake_case}} placeholders for \
            the parts the user should fill in, plus a matching field for each placeholder. \
            Choose a category from: \(categories). Do not solve the task.
            """
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: trimmed, generating: GeneratedTemplate.self)
                let gen = response.content
                let rawFields = gen.fields.map {
                    ComposedField(key: $0.key, label: $0.label, hint: $0.hint, multiline: $0.multiline)
                }
                guard let template = TemplateValidator.validate(
                    title: gen.title, category: gen.category, body: gen.body, fields: rawFields) else {
                    return .failure(.malformed, tier: tier)
                }
                return .success(template, tier: tier)
            } catch {
                return .failure(Self.mapError(error), tier: tier)
            }
        }
        #endif
        return .failure(.unavailable(.platformUnsupported), tier: tier)
    }

    // MARK: Chat (grounded)

    public func chat(question: String, context: [DocChunk]) async -> AIResult<DocAnswer> {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .failure(.malformed, tier: tier) }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            if let f = await probe() { return .failure(f, tier: tier) }
            let allowedIDs = context.map(\.id)
            let contextBlock = context
                .map { "[\($0.id)] \($0.title)\n\(HeuristicEngine.condense($0.text, maxChars: 1000))" }
                .joined(separator: "\n\n")
            let instructions = """
            Answer questions about developer CLI/agent tools using ONLY the provided \
            documentation excerpts. Each excerpt is prefixed with its id in brackets. \
            If the answer isn't in the excerpts, say so plainly. In citationIDs, list \
            only the excerpt ids you actually used.
            """
            let prompt = "Documentation excerpts:\n\n\(contextBlock)\n\n---\nQuestion: \(q)"
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: prompt, generating: GeneratedAnswer.self)
                let gen = response.content
                let answer = gen.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !answer.isEmpty else { return .failure(.malformed, tier: tier) }
                let valid = gen.citationIDs.filter { allowedIDs.contains($0) }
                let citations = valid.compactMap { id in
                    context.first(where: { $0.id == id }).map { Citation(chunkID: $0.id, title: $0.title) }
                }
                return .success(DocAnswer(answer: answer, citations: citations), tier: tier)
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

// MARK: - @Generable structured-output mirrors (gated)

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct GeneratedField {
    @Guide(description: "snake_case identifier matching a {{placeholder}} in the body")
    var key: String
    @Guide(description: "Short human-readable label")
    var label: String
    @Guide(description: "One-line hint describing what to enter")
    var hint: String
    @Guide(description: "True if the field expects multi-line text like code")
    var multiline: Bool
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct GeneratedTemplate {
    @Guide(description: "Short, descriptive title for the template")
    var title: String
    @Guide(description: "Category keyword (e.g. refactor, tests, debug, review, explain, git, docs, scaffold, general)")
    var category: String
    @Guide(description: "Prompt body containing {{snake_case}} placeholders for fill-in parts")
    var body: String
    @Guide(description: "One entry per placeholder in the body")
    var fields: [GeneratedField]
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct GeneratedAnswer {
    @Guide(description: "The answer, grounded only in the supplied excerpts")
    var answer: String
    @Guide(description: "Ids of the excerpts actually used, e.g. [\"abc\"]")
    var citationIDs: [String]
}
#endif
