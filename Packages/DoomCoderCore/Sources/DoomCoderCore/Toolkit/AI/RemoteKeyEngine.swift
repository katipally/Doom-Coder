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
        case .openai:    request = openAIRequest(system: system, user: user, temperature: temperature, maxTokens: maxTokens)
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
        case .openai:    text = Self.parseOpenAI(data)
        case .anthropic: text = Self.parseAnthropic(data)
        }
        guard let result = text, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.malformed)
        }
        return .success(result)
    }

    private func openAIRequest(system: String, user: String, temperature: Double, maxTokens: Int) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        let body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
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

    static func parseOpenAI(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
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
