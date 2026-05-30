// RemoteKeyEngine.swift — DoomCoderCore
// BYO-key engine. Sends requests device → provider (OpenAI / Anthropic) over
// HTTPS using the USER's key. DoomCoder runs no server and never sees the key.
// Used ONLY when the user explicitly selects "My API key" — never as a silent
// fallback for on-device content. Actor-isolated for session safety.

import Foundation

public actor RemoteKeyEngine: AIEngine {
    public nonisolated let tier: AITier = .remoteKey

    private let provider: AIProvider
    private let model: String
    private let apiKey: String

    public init(provider: AIProvider, model: String?, apiKey: String) {
        self.provider = provider
        self.model = (model?.isEmpty == false ? model! : provider.defaultModel)
        self.apiKey = apiKey
    }

    public func probe() async -> AIFailure? {
        apiKey.isEmpty ? .missingKey : nil
    }

    // MARK: Capabilities

    public func enhance(_ raw: String) async -> AIResult<String> {
        let idea = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty else { return .failure(.malformed, tier: tier) }
        let system = """
        You are an expert prompt engineer for AI coding agents (Claude Code, Codex, \
        Copilot CLI, etc.). Rewrite the user's rough request into a single, clear, \
        well-structured prompt. Preserve their intent. Add concise sections for \
        context, requirements, and expected output where helpful. Do NOT answer or \
        solve the request — only return the improved prompt text, with no preamble, \
        commentary, or code fences.
        """
        let result = await complete(system: system, user: idea, temperature: 0.4, maxTokens: 1200)
        switch result {
        case .failure(let f): return .failure(f, tier: tier)
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .failure(.malformed, tier: tier) : .success(trimmed, tier: tier)
        }
    }

    // MARK: - Transport

    private enum Completion {
        case success(String)
        case failure(AIFailure)
    }

    private func complete(system: String, user: String, temperature: Double, maxTokens: Int) async -> Completion {
        guard !apiKey.isEmpty else { return .failure(.missingKey) }
        if Task.isCancelled { return .failure(.cancelled) }

        let request: URLRequest
        switch provider {
        case .openai:    request = openAIRequest(system: system, user: user, maxTokens: maxTokens)
        case .anthropic: request = anthropicRequest(system: system, user: user, temperature: temperature, maxTokens: maxTokens)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.network("Invalid response")) }
        if http.statusCode == 429 { return .failure(.rateLimited) }
        guard (200...299).contains(http.statusCode) else {
            return .failure(.provider(http.statusCode, Self.providerErrorMessage(data)))
        }
        let text: String?
        switch provider {
        case .openai:    text = Self.parseOpenAIResponses(data)
        case .anthropic: text = Self.parseAnthropic(data)
        }
        guard let result = text, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.malformed)
        }
        return .success(result)
    }

    /// Builds an OpenAI request against the **Responses API** (`/v1/responses`).
    /// We deliberately do NOT send `temperature` or `max_tokens`: GPT-5 / GPT-5.x
    /// and the o-series reasoning models reject any non-default `temperature`
    /// (HTTP 400) and reject `max_tokens` (they use `max_output_tokens`). The
    /// Responses API + omitting sampling params works uniformly for both classic
    /// (gpt-4o, gpt-4-turbo, …) and reasoning models, so a single code path
    /// supports every model the user can pick. `max_output_tokens` also counts
    /// reasoning tokens, so it must be generous or reasoning models return empty
    /// output before producing any visible text.
    private func openAIRequest(system: String, user: String, maxTokens: Int) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        let body: [String: Any] = [
            "model": model,
            "instructions": system,
            "input": user,
            "max_output_tokens": max(maxTokens, 4000)
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func anthropicRequest(system: String, user: String, temperature: Double, maxTokens: Int) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 30
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Parsing

    /// Parses an OpenAI **Responses API** payload. Prefers the `output_text`
    /// convenience field; falls back to concatenating text from the structured
    /// `output[].content[]` array (type `output_text`), which is what reasoning
    /// models return alongside their reasoning items.
    static func parseOpenAIResponses(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // 1. Convenience aggregate field (string, or array of strings in some SDKs).
        if let text = json["output_text"] as? String, !text.isEmpty { return text }
        if let parts = json["output_text"] as? [String] {
            let joined = parts.joined()
            if !joined.isEmpty { return joined }
        }

        // 2. Walk the structured output: output[] → content[] → { type: "output_text", text }.
        guard let output = json["output"] as? [[String: Any]] else { return nil }
        let text = output.compactMap { item -> String? in
            guard let content = item["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { block -> String? in
                (block["type"] as? String) == "output_text" ? block["text"] as? String : nil
            }.joined()
        }.joined()
        return text.isEmpty ? nil : text
    }

    static func parseAnthropic(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { block -> String? in
            (block["type"] as? String) == "text" ? block["text"] as? String : nil
        }.joined()
        return text.isEmpty ? nil : text
    }

    static func providerErrorMessage(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return "" }
        return message
    }

    // MARK: - Live model listing + key test

    public struct ModelInfo: Sendable, Identifiable, Hashable {
        public let id: String
        public init(id: String) { self.id = id }
    }

    /// Validates a key AND returns the models available to it (key-scoped). Used
    /// by the "Test key" button which both checks the key and fills the picker.
    public static func listModels(provider: AIProvider, apiKey: String) async -> Result<[ModelInfo], AIFailure> {
        guard !apiKey.isEmpty else { return .failure(.missingKey) }
        var req = URLRequest(url: provider.modelsURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        switch provider {
        case .openai:
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.network("Invalid response")) }
        if http.statusCode == 401 || http.statusCode == 403 {
            return .failure(.provider(http.statusCode, "Invalid API key."))
        }
        if http.statusCode == 429 { return .failure(.rateLimited) }
        guard (200...299).contains(http.statusCode) else {
            return .failure(.provider(http.statusCode, providerErrorMessage(data)))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else {
            return .failure(.malformed)
        }
        let ids = arr.compactMap { $0["id"] as? String }
        let models = Self.preferredOrder(ids: ids, provider: provider).map { ModelInfo(id: $0) }
        return models.isEmpty ? .failure(.malformed) : .success(models)
    }

    /// Filters to relevant chat models and sorts newest/most-capable first.
    static func preferredOrder(ids: [String], provider: AIProvider) -> [String] {
        let filtered: [String]
        switch provider {
        case .openai:
            filtered = ids.filter { $0.hasPrefix("gpt") || $0.hasPrefix("o1") || $0.hasPrefix("o3") || $0.hasPrefix("o4") || $0.hasPrefix("chatgpt") }
        case .anthropic:
            filtered = ids.filter { $0.hasPrefix("claude") }
        }
        let base = filtered.isEmpty ? ids : filtered
        return base.sorted(by: >)
    }
}
