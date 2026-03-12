// RemoteKeyEngine.swift — DoomCodeCore
// BYO-key engine. Sends requests device → provider (OpenAI / Anthropic) over
// HTTPS using the USER's key. Doom Coder runs no server and never sees the key.
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

    /// Shared system prompt for the BYO-key engine. Emphatic that the input is a
    /// request to REWRITE, never a question to answer — matching the on-device
    /// engine so both tiers behave identically.
    static let systemPrompt = """
    You are a prompt engineer for AI coding agents (Claude Code, Codex, Copilot \
    CLI, etc.). Your ONLY job is to rewrite the user's text into one clear, \
    well-structured PROMPT they can paste into a coding agent. The user's text is \
    ALWAYS a rough request to be rewritten — NEVER a question to answer or a task \
    to perform. Do not solve it, do not write code, do not explain. Preserve \
    intent; briefly state context, the concrete task, and the expected output. \
    Keep it tight — no filler, no preamble, no commentary, no code fences. When \
    the conversation already contains a refined prompt and a new instruction, \
    apply that instruction to the existing prompt and return the full updated \
    prompt.
    """

    public func enhance(_ raw: String) async -> AIResult<String> {
        let idea = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty else { return .failure(.malformed, tier: tier) }
        let result = await complete(system: Self.systemPrompt, user: idea, temperature: 0.4, maxTokens: 1200)
        switch result {
        case .failure(let f): return .failure(f, tier: tier)
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .failure(.malformed, tier: tier) : .success(trimmed, tier: tier)
        }
    }

    // MARK: Stream (SSE)

    /// Streams a refined prompt over Server-Sent Events. `nonisolated` so it can
    /// satisfy the synchronous protocol requirement; it reads only the engine's
    /// immutable `let` configuration, so no actor hop is needed.
    public nonisolated func stream(transcript: [AIChatTurn]) -> AsyncThrowingStream<String, Error> {
        let provider = self.provider
        let model = self.model
        let apiKey = self.apiKey
        let messages = transcript.map { ChatTurnPayload(role: $0.role == .assistant ? "assistant" : "user", content: $0.text) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard !apiKey.isEmpty else {
                    continuation.finish(throwing: AIFailure.missingKey)
                    return
                }
                guard messages.contains(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    continuation.finish(throwing: AIFailure.malformed)
                    return
                }
                do {
                    let request = Self.streamRequest(provider: provider, model: model, apiKey: apiKey,
                                                     system: Self.systemPrompt, messages: messages)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: AIFailure.network("Invalid response"))
                        return
                    }
                    if http.statusCode == 429 {
                        continuation.finish(throwing: AIFailure.rateLimited)
                        return
                    }
                    guard (200...299).contains(http.statusCode) else {
                        // Drain the (small) error body for a useful message.
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        continuation.finish(throwing: AIFailure.provider(http.statusCode, Self.providerErrorMessage(data)))
                        return
                    }
                    var accumulated = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let delta = Self.parseSSELine(line, provider: provider) else { continue }
                        if delta.isEmpty { continue }
                        accumulated += delta
                        continuation.yield(accumulated)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AIFailure.cancelled)
                } catch {
                    continuation.finish(throwing: AIFailure.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct ChatTurnPayload: Sendable {
        let role: String
        let content: String
    }

    /// Builds a streaming (`stream: true`) request with a multi-turn message
    /// array for either provider.
    nonisolated static func streamRequest(provider: AIProvider, model: String, apiKey: String,
                                          system: String, messages: [ChatTurnPayload]) -> URLRequest {
        switch provider {
        case .openai:
            var req = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 120
            let input = messages.map { ["role": $0.role, "content": $0.content] }
            let body: [String: Any] = [
                "model": model,
                "instructions": system,
                "input": input,
                "max_output_tokens": 4000,
                "stream": true
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return req
        case .anthropic:
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.timeoutInterval = 120
            let msgs = messages.map { ["role": $0.role, "content": $0.content] }
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 1200,
                "temperature": 0.4,
                "system": system,
                "messages": msgs,
                "stream": true
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return req
        }
    }

    /// Extracts the incremental text delta from a single SSE line, or nil for
    /// lines that carry no text (event headers, pings, `[DONE]`, etc.).
    nonisolated static func parseSSELine(_ line: String, provider: AIProvider) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        switch provider {
        case .openai:
            // Responses API: incremental text arrives as `response.output_text.delta`.
            if type == "response.output_text.delta" { return json["delta"] as? String }
            return nil
        case .anthropic:
            // Messages API: text arrives as `content_block_delta` → `text_delta`.
            if type == "content_block_delta",
               let delta = json["delta"] as? [String: Any],
               (delta["type"] as? String) == "text_delta" {
                return delta["text"] as? String
            }
            return nil
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
