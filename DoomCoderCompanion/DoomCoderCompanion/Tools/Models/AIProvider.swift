// AIProvider.swift — DoomCoder Companion (Tools)
// Provider selection for the optional BYO-key "Smart enhance" feature. The user
// supplies their OWN API key (stored in the Keychain); requests go device →
// provider directly over HTTPS. DoomCoder operates no server and sees no key.

import Foundation

enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openai
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai:    return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    /// Default model used for prompt enhancement (kept lightweight/cheap).
    var defaultModel: String {
        switch self {
        case .openai:    return "gpt-4o-mini"
        case .anthropic: return "claude-3-5-haiku-latest"
        }
    }

    var keyHint: String {
        switch self {
        case .openai:    return "sk-…"
        case .anthropic: return "sk-ant-…"
        }
    }

    var consoleURL: URL {
        switch self {
        case .openai:    return URL(string: "https://platform.openai.com/api-keys")!
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        }
    }
}
