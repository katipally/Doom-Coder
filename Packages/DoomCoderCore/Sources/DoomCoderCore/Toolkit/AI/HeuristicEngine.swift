// HeuristicEngine.swift — DoomCoderCore
// Tier 3: deterministic, fully-offline AI engine. Always available, no key, no
// network, no Apple Intelligence. This is NOT an emergency stub — it is a
// first-class backend so every Tools feature works on every device (App Store
// 4.2.3 standalone requirement). Same input → same output.

import Foundation

public struct HeuristicEngine: AIEngine {
    public let tier: AITier = .heuristic

    public init() {}

    public func probe() async -> AIFailure? { nil } // always available

    // MARK: Enhance

    public func enhance(_ raw: String) async -> AIResult<String> {
        let idea = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty else { return .failure(.malformed, tier: tier) }

        let task = idea.hasSuffix(".") ? String(idea.dropLast()) : idea
        let role = Self.inferredRole(for: idea)
        let text = """
        You are \(role).

        Task:
        \(Self.capitalizingFirst(task)).

        Context:
        - <describe the project, language, framework, and any relevant files>
        - <paste the exact code, error output, or logs that matter>

        Requirements:
        - Keep changes minimal and focused on the task.
        - Follow the existing conventions and style of the codebase.
        - Call out any assumptions, edge cases, or trade-offs.
        - Production-quality: handle errors and avoid breaking existing behavior.

        Expected output:
        - The complete, working solution.
        - A short explanation of the key decisions.
        """
        return .success(text, tier: tier)
    }

    // MARK: Compose

    public func compose(intent: String) async -> AIResult<ComposedTemplate> {
        let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.malformed, tier: tier) }

        let role = Self.inferredRole(for: trimmed)
        let category = Self.inferredCategory(for: trimmed)
        let title = Self.deriveTitle(from: trimmed)

        let body = """
        You are \(role).

        Task:
        \(Self.capitalizingFirst(Self.stripTrailingPeriod(trimmed))).

        Context:
        {{context}}

        Constraints:
        {{requirements}}

        Expected output:
        {{expected_output}}
        """

        // Funnel through the validator so the heuristic emits the exact same
        // trustworthy format as the model-backed tiers.
        let fields = [
            ComposedField(key: "context", label: "Context", hint: "Project, language, files, and the exact code/errors that matter.", multiline: true),
            ComposedField(key: "requirements", label: "Constraints", hint: "Must-dos, style, edge cases, things to avoid.", multiline: true),
            ComposedField(key: "expected_output", label: "Expected output", hint: "What a complete answer looks like.", multiline: true)
        ]
        if let template = TemplateValidator.validate(title: title, category: category.rawValue, body: body, fields: fields) {
            return .success(template, tier: tier)
        }
        return .failure(.malformed, tier: tier)
    }

    // MARK: Chat (grounded in supplied chunks only)

    public func chat(question: String, context: [DocChunk]) async -> AIResult<DocAnswer> {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .failure(.malformed, tier: tier) }
        guard !context.isEmpty else {
            return .success(DocAnswer(
                answer: "I couldn't find anything about that in the bundled documentation. Try rephrasing, or run the tool's `--help` for the latest details.",
                citations: []), tier: tier)
        }

        // Context is already ranked by the caller (DocsService retrieval). Stitch
        // the most relevant passages and cite exactly those chunks.
        let top = Array(context.prefix(2))
        let stitched = top.map { chunk -> String in
            let snippet = Self.condense(chunk.text, maxChars: 600)
            return "From “\(chunk.title)”:\n\(snippet)"
        }.joined(separator: "\n\n")

        let answer = """
        Here's what the documentation says:

        \(stitched)
        """
        let citations = top.map { Citation(chunkID: $0.id, title: $0.title) }
        return .success(DocAnswer(answer: answer, citations: citations), tier: tier)
    }

    // MARK: - Heuristics

    static func inferredRole(for idea: String) -> String {
        let lower = idea.lowercased()
        if lower.contains("test") {
            return "an expert software engineer who writes thorough, reliable tests"
        }
        if lower.contains("refactor") || lower.contains("clean") {
            return "a senior engineer who refactors code for clarity and maintainability"
        }
        if lower.contains("debug") || lower.contains("fix") || lower.contains("error") || lower.contains("bug") {
            return "a meticulous debugger who finds root causes, not just symptoms"
        }
        if lower.contains("review") {
            return "a rigorous code reviewer focused on correctness and security"
        }
        if lower.contains("explain") || lower.contains("understand") {
            return "a patient mentor who explains code clearly and concisely"
        }
        if lower.contains("document") || lower.contains("docs") || lower.contains("comment") {
            return "a technical writer who documents code accurately for developers"
        }
        return "an expert software engineer and pair programmer"
    }

    static func inferredCategory(for idea: String) -> PromptCategory {
        let lower = idea.lowercased()
        if lower.contains("test") { return .tests }
        if lower.contains("refactor") || lower.contains("clean") { return .refactor }
        if lower.contains("debug") || lower.contains("fix") || lower.contains("bug") || lower.contains("error") { return .debug }
        if lower.contains("review") { return .review }
        if lower.contains("explain") || lower.contains("understand") { return .explain }
        if lower.contains("git") || lower.contains("commit") || lower.contains("merge") { return .git }
        if lower.contains("document") || lower.contains("docs") { return .docs }
        if lower.contains("scaffold") || lower.contains("boilerplate") || lower.contains("set up") || lower.contains("create a") { return .scaffold }
        return .general
    }

    static func deriveTitle(from idea: String) -> String {
        let words = idea.split(whereSeparator: { $0 == " " || $0 == "\n" }).prefix(7).joined(separator: " ")
        return capitalizingFirst(stripTrailingPeriod(words))
    }

    static func stripTrailingPeriod(_ s: String) -> String {
        s.hasSuffix(".") ? String(s.dropLast()) : s
    }

    static func capitalizingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    static func condense(_ text: String, maxChars: Int) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxChars { return collapsed }
        return String(collapsed.prefix(maxChars)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
