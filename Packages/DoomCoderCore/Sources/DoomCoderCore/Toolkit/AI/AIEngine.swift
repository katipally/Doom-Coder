// AIEngine.swift — DoomCoderCore
// Core types + protocol for the shared 3-tier AI engine used by both the macOS
// app and the iOS companion. Tiers, in priority order:
//   1. .appleOnDevice — Apple FoundationModels (on-device, offline, free, private)
//   2. .remoteKey     — BYO-key OpenAI / Anthropic (opt-in; content leaves device)
//   3. .heuristic     — deterministic offline (always available, product-quality)
//
// Privacy: in "automatic" selection the engine NEVER sends on-device content to a
// remote provider — remote is used ONLY when the user explicitly selects it. This
// keeps the standalone experience private and App Store 4.2.3 / privacy-safe.

import Foundation

/// Which backend produced (or was asked to produce) a result.
public enum AITier: String, Codable, Sendable, CaseIterable, Identifiable {
    case appleOnDevice
    case remoteKey
    case heuristic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleOnDevice: return "On-device (Apple Intelligence)"
        case .remoteKey:     return "My API key"
        case .heuristic:     return "Built-in (offline)"
        }
    }

    public var shortName: String {
        switch self {
        case .appleOnDevice: return "On-device"
        case .remoteKey:     return "API key"
        case .heuristic:     return "Built-in"
        }
    }
}

/// Why an on-device (or any) tier is unavailable — drives actionable UI copy.
public enum AIUnavailableReason: Sendable, Equatable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case platformUnsupported
    case unknown(String)

    public var message: String {
        switch self {
        case .deviceNotEligible:
            return "This device doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to use on-device AI."
        case .modelNotReady:
            return "The on-device model is still downloading. Try again shortly."
        case .platformUnsupported:
            return "On-device AI requires iOS 26 or macOS 26."
        case .unknown(let detail):
            return detail.isEmpty ? "On-device AI is unavailable." : detail
        }
    }
}

/// A normalized failure that any tier can report.
public enum AIFailure: Error, Sendable, Equatable {
    /// The tier cannot run at all (device/OS/Apple Intelligence gating).
    case unavailable(AIUnavailableReason)
    /// The model produced output that failed deterministic validation.
    case malformed
    /// The model's safety guardrails refused the request.
    case safetyRefusal
    /// Provider rate limit / quota.
    case rateLimited
    /// Transport-level error (offline, timeout, DNS, …).
    case network(String)
    /// Provider returned a non-2xx HTTP status.
    case provider(Int, String)
    /// No API key configured for the selected provider.
    case missingKey
    /// The request was cancelled by the caller.
    case cancelled

    public var message: String {
        switch self {
        case .unavailable(let r):    return r.message
        case .malformed:             return "The AI returned an unexpected format."
        case .safetyRefusal:         return "The AI declined to answer this request."
        case .rateLimited:           return "Rate limited by the provider. Try again soon."
        case .network(let m):        return m.isEmpty ? "Network error." : "Network error: \(m)"
        case .provider(let code, let m):
            return "Provider returned \(code).\(m.isEmpty ? "" : " \(m)")"
        case .missingKey:            return "No API key set for this provider."
        case .cancelled:             return "Cancelled."
        }
    }

    /// True for failures the user can act on (vs. ones we silently fall back from
    /// in automatic mode).
    public var isActionable: Bool {
        switch self {
        case .network, .provider, .rateLimited, .missingKey: return true
        case .unavailable, .malformed, .safetyRefusal, .cancelled: return false
        }
    }
}

/// Outcome of an AI operation, tagged with the tier that handled it.
public enum AIResult<T: Sendable>: Sendable {
    case success(T, tier: AITier)
    case failure(AIFailure, tier: AITier?)

    public var value: T? {
        if case .success(let v, _) = self { return v }
        return nil
    }
    public var failure: AIFailure? {
        if case .failure(let f, _) = self { return f }
        return nil
    }
    public var tier: AITier? {
        switch self {
        case .success(_, let t): return t
        case .failure(_, let t): return t
        }
    }
}

// MARK: - Composer output (tier-agnostic, validated)

/// A single fill-in field the composer produced for a template.
public struct ComposedField: Codable, Sendable, Hashable {
    public var key: String
    public var label: String
    public var hint: String
    public var multiline: Bool

    public init(key: String, label: String, hint: String = "", multiline: Bool = false) {
        self.key = key
        self.label = label
        self.hint = hint
        self.multiline = multiline
    }
}

/// A validated, reusable prompt template emitted by the composer. `body` is
/// guaranteed to contain only strict `{{snake_case}}` tokens, and every token has
/// a matching entry in `fields`.
public struct ComposedTemplate: Codable, Sendable, Hashable {
    public var title: String
    public var category: PromptCategory
    public var body: String
    public var fields: [ComposedField]

    public init(title: String, category: PromptCategory, body: String, fields: [ComposedField]) {
        self.title = title
        self.category = category
        self.body = body
        self.fields = fields
    }

    /// Converts to a persistable `Prompt`.
    public func toPrompt() -> Prompt {
        Prompt(
            title: title,
            category: category,
            body: body,
            fields: fields.map { PromptField(key: $0.key, label: $0.label, hint: $0.hint, multiline: $0.multiline) },
            tags: [],
            isCurated: false
        )
    }
}

// MARK: - Docs chat (grounded, with citations)

/// A retrieved documentation passage passed into `chat`. The engine may only cite
/// chunks present in the supplied context.
public struct DocChunk: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let source: String?
    public let text: String

    public init(id: String, title: String, source: String? = nil, text: String) {
        self.id = id
        self.title = title
        self.source = source
        self.text = text
    }
}

/// A citation referencing a `DocChunk.id` from the supplied context.
public struct Citation: Codable, Sendable, Hashable, Identifiable {
    public let chunkID: String
    public let title: String
    public var id: String { chunkID }

    public init(chunkID: String, title: String) {
        self.chunkID = chunkID
        self.title = title
    }
}

/// A grounded answer with citations limited to the supplied context.
public struct DocAnswer: Codable, Sendable, Hashable {
    public var answer: String
    public var citations: [Citation]

    public init(answer: String, citations: [Citation] = []) {
        self.answer = answer
        self.citations = citations
    }
}

// MARK: - Engine protocol

/// A single AI backend. All three tiers implement every capability so the product
/// is fully usable with no key and no Apple Intelligence (App Store 4.2.3 safe).
public protocol AIEngine: Sendable {
    var tier: AITier { get }

    /// `nil` when the tier can run; otherwise the reason it can't.
    func probe() async -> AIFailure?

    /// Rewrites a rough idea into a clear, structured prompt.
    func enhance(_ raw: String) async -> AIResult<String>

    /// Builds a reusable template (body + fill-in fields) from a freeform intent.
    func compose(intent: String) async -> AIResult<ComposedTemplate>

    /// Answers a question grounded ONLY in the supplied documentation chunks.
    func chat(question: String, context: [DocChunk]) async -> AIResult<DocAnswer>
}
