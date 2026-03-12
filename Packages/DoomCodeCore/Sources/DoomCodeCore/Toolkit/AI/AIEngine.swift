// AIEngine.swift — DoomCodeCore
// Core types + protocol for the shared AI engine used by both the macOS app and
// the iOS companion. Two user-selectable backends:
//   1. .appleOnDevice — Apple FoundationModels (on-device, offline, free, private)
//   2. .remoteKey     — BYO-key OpenAI / Anthropic (opt-in; content leaves device)
//
// Privacy: remote is used ONLY when the user explicitly selects "My API key" —
// on-device content is never sent to a provider automatically. Manual prompt
// authoring + Notes work with no AI at all, keeping the app standalone
// (App Store 4.2.3 / privacy-safe).

import Foundation

/// Which backend produced (or was asked to produce) a result.
public enum AITier: String, Codable, Sendable, CaseIterable, Identifiable {
    case appleOnDevice
    case remoteKey

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleOnDevice: return "On-device (Apple Intelligence)"
        case .remoteKey:     return "My API key"
        }
    }

    public var shortName: String {
        switch self {
        case .appleOnDevice: return "On-device"
        case .remoteKey:     return "API key"
        }
    }
}

/// Why an on-device (or any) tier is unavailable — drives actionable UI copy.
public enum AIUnavailableReason: Sendable, Equatable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case platformUnsupported
    case simulatorUnsupported
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
        case .simulatorUnsupported:
            return "On-device AI isn't available in the iOS Simulator. Run on a real device, or choose “My API key.”"
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

    /// True for failures the user can act on (e.g. add a key, retry) vs. ones
    /// that just need a clear message (unsupported device, safety refusal).
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

// MARK: - Transcript

/// A single turn fed to an engine when refining. The transcript lets follow-up
/// instructions ("make it shorter", "go back to the earlier version") stay
/// coherent across multiple refinements and across BOTH engines — every engine
/// reconstructs context from this transcript on each call and holds no live
/// session state of its own.
public struct AIChatTurn: Sendable, Hashable {
    public let role: ChatRole
    public let text: String
    public init(role: ChatRole, text: String) {
        self.role = role
        self.text = text
    }
}

// MARK: - Engine protocol

/// A single AI backend. Both tiers implement every capability. The app stays
/// usable with no key and no Apple Intelligence because manual authoring + Notes
/// need no AI (App Store 4.2.3 safe).
public protocol AIEngine: Sendable {
    var tier: AITier { get }

    /// `nil` when the tier can run; otherwise the reason it can't.
    func probe() async -> AIFailure?

    /// Rewrites a rough idea into a clear, structured prompt.
    func enhance(_ raw: String) async -> AIResult<String>

    /// Streams a refined prompt for the given transcript. The first turn is the
    /// user's rough idea; later assistant/user turns drive iterative refinement.
    /// Each yielded value is the **cumulative** text so far (not a delta), so the
    /// UI can simply assign it to the in-flight message. Throws `AIFailure` on
    /// error and honors task cancellation (Stop button) by finishing early.
    func stream(transcript: [AIChatTurn]) -> AsyncThrowingStream<String, Error>
}

public extension AIEngine {
    /// Non-streaming convenience: drains `stream(transcript:)` to a final result,
    /// tagged with this engine's tier. Used as a fallback where streaming UI
    /// isn't needed.
    func refine(transcript: [AIChatTurn]) async -> AIResult<String> {
        var latest = ""
        do {
            for try await chunk in stream(transcript: transcript) {
                latest = chunk
            }
            let trimmed = latest.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .failure(.malformed, tier: tier) : .success(trimmed, tier: tier)
        } catch let failure as AIFailure {
            return .failure(failure, tier: tier)
        } catch is CancellationError {
            return .failure(.cancelled, tier: tier)
        } catch {
            return .failure(.malformed, tier: tier)
        }
    }
}
