// OfflineEnhancer.swift — DoomCoder Companion (Tools)
// Deterministic, fully-offline prompt structuring. Turns a rough idea into a
// well-formed prompt for an AI coding agent using a proven scaffold (role, task,
// context, requirements, output format). No network, no key required.

import Foundation

enum OfflineEnhancer {

    /// Rewrites a rough idea into a structured prompt. Pure function — same input
    /// always yields the same output.
    static func enhance(_ raw: String) -> String {
        let idea = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty else { return idea }

        let task = idea.hasSuffix(".") ? String(idea.dropLast()) : idea
        let role = inferredRole(for: idea)

        return """
        You are \(role).

        Task:
        \(capitalizingFirst(task)).

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
    }

    private static func inferredRole(for idea: String) -> String {
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

    private static func capitalizingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
