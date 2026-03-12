// AIProvider.swift — DoomCoderCore
// BYO-key provider selection for Tier 2. The user supplies their OWN API key
// (stored in the Keychain); requests go device → provider directly over HTTPS.
// DoomCoder operates no server and never sees the key.

import Foundation

public enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openai
    case anthropic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openai:    return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    /// Default chat model used when the user hasn't picked one.
    public var defaultModel: String {
        switch self {
        case .openai:    return "gpt-4o-mini"
        case .anthropic: return "claude-3-5-haiku-latest"
        }
    }

    public var keyHint: String {
        switch self {
        case .openai:    return "sk-…"
        case .anthropic: return "sk-ant-…"
        }
    }

    public var consoleURL: URL {
        switch self {
        case .openai:    return URL(string: "https://platform.openai.com/api-keys")!
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        }
    }

    /// Key-scoped endpoint that lists the models available to this key.
    public var modelsURL: URL {
        switch self {
        case .openai:    return URL(string: "https://api.openai.com/v1/models")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/models")!
        }
    }
}
