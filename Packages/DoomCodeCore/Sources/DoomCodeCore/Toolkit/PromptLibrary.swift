// PromptLibrary.swift — DoomCodeCore
// A shared, built-in library of genuinely useful, copy-ready prompts for AI
// coding agents. Used by BOTH the macOS app and the iOS companion so the Tools
// experience delivers real standalone value with ZERO setup — no AI, no API key,
// and no Mac connection required. Every prompt is hand-written, professional, and
// immediately pasteable into Claude Code, Copilot, Cursor, Codex, etc.
//
// These are read-only built-ins (isCurated = true). The UI lets the user copy a
// prompt directly, or open it in the composer to tailor it. Placeholders use the
// `{{token}}` syntax shared with `Prompt.render(values:)`; when left blank they
// render as `[token]`, so a copied prompt is always usable as-is.

import Foundation

/// Curated, copy-ready prompts shipped with the app. Pure data — no I/O, no state.
public enum PromptLibrary {

    /// Every built-in prompt, in a sensible browsing order.
    public static let all: [Prompt] = refactor + tests + debug + review + explain + git + docs + scaffold

    /// Built-in prompts grouped by category, preserving `all`'s order.
    public static func grouped() -> [(category: PromptCategory, prompts: [Prompt])] {
        PromptCategory.allCases.compactMap { cat in
            let items = all.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    private static func p(_ title: String,
                          _ category: PromptCategory,
                          _ body: String,
                          tags: [String] = []) -> Prompt {
        Prompt(title: title, category: category, body: body, tags: tags, isCurated: true)
    }

    // MARK: - Refactor

    private static let refactor: [Prompt] = [
        p("Refactor for readability", .refactor, """
        Refactor the following code to improve readability and maintainability \
        without changing its behavior. Keep the public API and observable \
        behavior identical. Prefer clear names, small focused functions, and \
        early returns over deep nesting. Explain each change in one short line.

        ```{{language}}
        {{code}}
        ```
        """, tags: ["clean code", "readability"]),

        p("Extract a reusable function", .refactor, """
        Extract the repeated or tangled logic below into a single, well-named, \
        reusable function. Define a clear signature, document the parameters and \
        return value, and update every call site. Do not change behavior.

        ```{{language}}
        {{code}}
        ```
        """, tags: ["dry", "extract"]),

        p("Simplify a complex condition", .refactor, """
        Simplify this conditional logic. Remove redundant branches, flatten \
        nesting with guard/early-return, and introduce well-named boolean \
        variables for any non-obvious checks. Preserve the exact truth table.

        ```{{language}}
        {{code}}
        ```
        """, tags: ["conditionals"]),

        p("Modernize legacy code", .refactor, """
        Modernize this code to current {{language}} idioms and standard-library \
        APIs. Replace deprecated calls, adopt safer patterns, and note any \
        behavioral differences I should verify. List the upgrades as a short \
        bulleted summary at the end.

        ```{{language}}
        {{code}}
        ```
        """, tags: ["modernize", "legacy"]),
    ]

    // MARK: - Tests

    private static let tests: [Prompt] = [
        p("Write unit tests", .tests, """
        Write thorough unit tests for the code below using {{framework}}. Cover \
        the happy path, edge cases, boundary values, and error conditions. Use \
        clear test names that describe the scenario and expected result. Avoid \
        testing implementation details — assert on observable behavior.

        ```{{language}}
        {{code}}
        ```
        """, tags: ["testing", "coverage"]),

        p("Add a failing test first (TDD)", .tests, """
        I want to add this behavior using test-driven development: {{behavior}}

        Write a single, minimal failing test that captures the new requirement \
        before any implementation exists. Explain what the test asserts and why \
        it should fail right now. Do not write the implementation yet.
        """, tags: ["tdd"]),

        p("Find missing test cases", .tests, """
        Review the code and its existing tests below. List the important \
        scenarios that are NOT yet covered — edge cases, error paths, concurrency, \
        and boundary inputs. For each gap, give a one-line test description. Do \
        not rewrite the existing tests.

        Code:
        ```{{language}}
        {{code}}
        ```

        Existing tests:
        ```{{language}}
        {{tests}}
        ```
        """, tags: ["coverage", "edge cases"]),
    ]

    // MARK: - Debug

    private static let debug: [Prompt] = [
        p("Debug an error", .debug, """
        I'm getting this error and need help finding the root cause:

        {{error}}

        Relevant code:
        ```{{language}}
        {{code}}
        ```

        Walk through the most likely causes from most to least probable. For the \
        top cause, explain why it happens and give the minimal fix. Don't change \
        unrelated code.
        """, tags: ["error", "root cause"]),

        p("Find the bug", .debug, """
        This code is producing the wrong result. Expected: {{expected}}. Actual: \
        {{actual}}. Trace the logic step by step, identify the exact line where it \
        goes wrong, and propose the smallest correct fix.

        ```{{language}}
        {{code}}
        ```
        """, tags: ["logic bug"]),

        p("Add diagnostic logging", .debug, """
        Add precise, temporary diagnostic logging to this code so I can pinpoint \
        why {{symptom}} happens at runtime. Log the key variables, branch taken, \
        and entry/exit of the suspect path. Mark each log so it's easy to remove \
        later.

        ```{{language}}
        {{code}}
        ```
        """, tags: ["logging", "diagnostics"]),

        p("Explain a stack trace", .debug, """
        Explain this stack trace in plain language. Identify the frame where the \
        real problem originates (not just where it surfaced), what likely caused \
        it, and the first thing I should check.

        {{stacktrace}}
        """, tags: ["stack trace"]),
    ]

    // MARK: - Review

    private static let review: [Prompt] = [
        p("Review my changes", .review, """
        Review the following diff like a senior engineer. Focus on correctness, \
        edge cases, naming, and maintainability. Flag anything risky. Be specific \
        and reference exact lines. Skip style nits unless they hurt readability. \
        End with a short verdict: ship, ship-with-nits, or needs-work.

        ```diff
        {{diff}}
        ```
        """, tags: ["code review", "pr"]),

        p("Security review", .review, """
        Perform a focused security review of the code below. Look for injection, \
        unsafe input handling, secrets in code, broken auth/authorization, unsafe \
        deserialization, and data exposure. For each finding give severity, the \
        risk, and a concrete fix. If you find nothing serious, say so plainly.

        ```{{language}}
        {{code}}
        ```
        """, tags: ["security", "audit"]),

        p("Performance review", .review, """
        Analyze this code for performance problems. Identify hot paths, \
        unnecessary allocations, repeated work, and any O(n²)-or-worse patterns. \
        Rank issues by likely impact and give a concrete optimization for each. \
        Don't micro-optimize cold paths.

        ```{{language}}
        {{code}}
        ```
        """, tags: ["performance"]),
    ]

    // MARK: - Explain

    private static let explain: [Prompt] = [
        p("Explain this code", .explain, """
        Explain what this code does in clear, plain language. Start with a \
        one-sentence summary, then walk through the important parts and the \
        non-obvious decisions. Call out any side effects, assumptions, or gotchas.

        ```{{language}}
        {{code}}
        ```
        """, tags: ["understand"]),

        p("Explain an error message", .explain, """
        Explain this error message as if to a teammate who's new to the codebase: \
        what it means, the common causes, and how to fix it. Keep it concrete.

        {{error}}
        """, tags: ["error"]),

        p("Compare two approaches", .explain, """
        I'm deciding between two approaches for {{goal}}:

        Option A: {{option_a}}
        Option B: {{option_b}}

        Compare them on correctness, complexity, performance, and long-term \
        maintenance. Give a clear recommendation with the trade-offs spelled out.
        """, tags: ["trade-offs", "decision"]),
    ]

    // MARK: - Git

    private static let git: [Prompt] = [
        p("Write a commit message", .git, """
        Write a clear, conventional commit message for the following diff. Use an \
        imperative subject under 72 characters, then a body explaining WHAT \
        changed and WHY (not how). Keep it concise.

        ```diff
        {{diff}}
        ```
        """, tags: ["commit", "conventional"]),

        p("Write a pull request description", .git, """
        Write a pull request description for these changes. Include a short \
        summary, the motivation/context, a bulleted list of key changes, and any \
        testing or review notes. Keep it skimmable.

        ```diff
        {{diff}}
        ```
        """, tags: ["pr", "review"]),

        p("Untangle a git situation", .git, """
        I'm stuck in this git state and want to fix it safely without losing work:

        {{situation}}

        Explain what state I'm in, then give the exact commands to recover, with a \
        one-line note on what each command does and which steps are destructive.
        """, tags: ["recovery"]),
    ]

    // MARK: - Docs

    private static let docs: [Prompt] = [
        p("Write documentation", .docs, """
        Write clear documentation comments for the public API below, following \
        the idiomatic doc style for {{language}}. Describe purpose, parameters, \
        return value, thrown errors, and a short usage example. Don't restate the \
        obvious.

        ```{{language}}
        {{code}}
        ```
        """, tags: ["docstrings", "api"]),

        p("Write a README section", .docs, """
        Write a README section for {{feature}}. Cover what it does, why it's \
        useful, a minimal usage example, and any setup or caveats. Use a friendly \
        but concise tone and proper Markdown headings.
        """, tags: ["readme"]),
    ]

    // MARK: - Scaffold

    private static let scaffold: [Prompt] = [
        p("Scaffold a feature", .scaffold, """
        I want to build this feature: {{feature}}

        Before writing code, propose a short implementation plan: the files to \
        add or change, the key types/functions and their responsibilities, and \
        the order to build them. Flag any decisions you need from me. Wait for my \
        go-ahead before implementing.
        """, tags: ["plan", "design"]),

        p("Plan before coding", .scaffold, """
        Here's the task: {{task}}

        Think through it before touching code. Restate the requirements in your \
        own words, list assumptions and open questions, outline the approach in \
        numbered steps, and call out edge cases and risks. Don't write code yet.
        """, tags: ["planning"]),

        p("Design an API", .scaffold, """
        Design a clean API for {{purpose}}. Propose the types, the key methods \
        with signatures, and the error model. Optimize for an obvious, hard-to-\
        misuse interface. Show a short usage example and note any trade-offs.
        """, tags: ["api design"]),
    ]
}
