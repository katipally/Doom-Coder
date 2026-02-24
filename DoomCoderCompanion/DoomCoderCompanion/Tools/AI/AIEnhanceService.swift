// AIEnhanceService.swift — DoomCoder Companion (Tools)
// BYO-key "Smart enhance": sends a rough prompt to the user's chosen provider
// (OpenAI or Anthropic) using THEIR key, device → provider over HTTPS. DoomCoder
// runs no server and never sees the key. Falls back to OfflineEnhancer on any
// failure so the feature always produces something useful.

import Foundation

enum AIEnhanceError: LocalizedError {
    case missingKey
    case http(Int, String)
    case emptyResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:        return "No API key set for this provider."
        case .http(let code, let msg):
            return "Provider returned \(code).\(msg.isEmpty ? "" : " \(msg)")"
        case .emptyResponse:     return "The provider returned an empty response."
        case .transport(let m):  return "Network error: \(m)"
        }
    }
}

enum AIEnhanceService {

    private static let systemPrompt = """
    You are an expert prompt engineer for AI coding agents (Claude Code, Codex, \
    Copilot CLI, etc.). Rewrite the user's rough request into a single, clear, \
    well-structured prompt. Preserve their intent. Add concise sections for \
    context, requirements, and expected output where helpful. Do NOT answer or \
    solve the request — only return the improved prompt text, with no preamble, \
    commentary, or code fences.
    """

    /// Sends the raw idea to the provider and returns the improved prompt.
    static func enhance(_ raw: String,
                        provider: AIProvider,
                        apiKey: String,
                        model: String? = nil) async throws -> String {
        let idea = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw AIEnhanceError.missingKey }
        let model = model ?? provider.defaultModel

        let request: URLRequest
        switch provider {
        case .openai:    request = try openAIRequest(idea: idea, apiKey: apiKey, model: model)
        case .anthropic: request = try anthropicRequest(idea: idea, apiKey: apiKey, model: model)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AIEnhanceError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIEnhanceError.transport("Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw AIEnhanceError.http(http.statusCode, providerErrorMessage(data))
        }

        let text: String?
        switch provider {
        case .openai:    text = parseOpenAI(data)
        case .anthropic: text = parseAnthropic(data)
        }
        guard let result = text?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else {
            throw AIEnhanceError.emptyResponse
        }
        return result
    }

    // MARK: - Request builders

    private static func openAIRequest(idea: String, apiKey: String, model: String) throws -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.4,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": idea]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func anthropicRequest(idea: String, apiKey: String, model: String) throws -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 30
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "temperature": 0.4,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": idea]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Response parsing

    private static func parseOpenAI(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }

    private static func parseAnthropic(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { block -> String? in
            (block["type"] as? String) == "text" ? block["text"] as? String : nil
        }.joined()
        return text.isEmpty ? nil : text
    }

    private static func providerErrorMessage(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return "" }
        return message
    }
}
