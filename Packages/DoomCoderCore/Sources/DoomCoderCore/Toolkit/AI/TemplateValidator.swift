// TemplateValidator.swift — DoomCoderCore
// Deterministic validation/repair for composer output. NEVER trusts an LLM's
// template or field metadata. Normalizes loose placeholder tokens to a strict
// `{{snake_case}}` grammar, rejects nested/unmatched braces, derives the field
// list from the PARSED body (not the model's claims), caps field count, and
// coerces the category to a known value. All three tiers funnel through this so
// they emit an identical, trustworthy template format.

import Foundation

public enum TemplateValidator {

    /// Hard cap on fill-in fields. Beyond this we consider the template unusable
    /// and let the caller fall back to the heuristic template.
    public static let maxFields = 12

    /// Validates + repairs raw composer output into a trustworthy template.
    /// Returns `nil` only when the body is irreparable (caller falls back).
    public static func validate(title rawTitle: String,
                                category rawCategory: String,
                                body rawBody: String,
                                fields rawFields: [ComposedField]) -> ComposedTemplate? {
        guard let normalizedBody = normalizeBody(rawBody) else { return nil }

        let keys = Prompt.placeholderKeys(in: normalizedBody)
        guard keys.count <= maxFields else { return nil }

        // Index model-provided metadata by normalized key (best-effort hints only).
        var metaByKey: [String: ComposedField] = [:]
        for f in rawFields {
            if let nk = normalizeKey(f.key) { metaByKey[nk] = f }
        }

        let fields: [ComposedField] = keys.map { key in
            let meta = metaByKey[key]
            let label = meta.flatMap { trimmedNonEmpty($0.label) } ?? deriveLabel(from: key)
            let hint = meta?.hint ?? ""
            let multiline = meta?.multiline ?? isMultiline(key)
            return ComposedField(key: key, label: label, hint: hint, multiline: multiline)
        }

        let title = trimmedNonEmpty(rawTitle) ?? deriveTitle(from: normalizedBody)
        let category = PromptCategory(rawValue: rawCategory.lowercased()) ?? .general

        return ComposedTemplate(title: title, category: category, body: normalizedBody, fields: fields)
    }

    // MARK: - Body normalization

    /// Walks the body, replacing each `{{ loose token }}` with `{{snake_case}}`.
    /// Returns `nil` on nested or unmatched braces.
    static func normalizeBody(_ body: String) -> String? {
        var output = ""
        let chars = Array(body)
        var i = 0
        let n = chars.count

        while i < n {
            if chars[i] == "{" && i + 1 < n && chars[i + 1] == "{" {
                // Find the closing "}}".
                guard let close = findClose(chars, from: i + 2) else { return nil } // unmatched
                let inner = String(chars[(i + 2)..<close])
                // Nested braces inside a token are invalid.
                if inner.contains("{") || inner.contains("}") { return nil }
                guard let key = normalizeKey(inner) else {
                    // Token with no usable identifier — drop the braces, keep text.
                    output += inner.trimmingCharacters(in: .whitespaces)
                    i = close + 2
                    continue
                }
                output += "{{\(key)}}"
                i = close + 2
            } else if chars[i] == "}" && i + 1 < n && chars[i + 1] == "}" {
                // Stray closing braces — unmatched.
                return nil
            } else {
                output.append(chars[i])
                i += 1
            }
        }
        return output
    }

    /// Index of the "{" that starts the next "}}" after `start`, or nil.
    private static func findClose(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i + 1 < chars.count {
            if chars[i] == "}" && chars[i + 1] == "}" { return i }
            i += 1
        }
        return nil
    }

    // MARK: - Key / label helpers

    /// Lowercases, converts spaces/hyphens/camelCase to `snake_case`, strips
    /// invalid characters, and ensures the result starts with a letter.
    static func normalizeKey(_ raw: String) -> String? {
        let s0 = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s0.isEmpty else { return nil }
        // Insert a boundary before an uppercase letter only when it starts a new
        // word: preceded by a lowercase/digit (fooBar → foo_Bar), or it's the last
        // uppercase of an acronym run followed by a lowercase (APIKey → API_Key).
        // This keeps acronym runs like "API" intact instead of "a_p_i".
        let chars = Array(s0)
        var spaced = ""
        for (idx, ch) in chars.enumerated() {
            if ch.isUppercase && idx > 0 {
                let prev = chars[idx - 1]
                let next: Character? = idx + 1 < chars.count ? chars[idx + 1] : nil
                let prevIsLowerOrDigit = prev.isLowercase || prev.isNumber
                let acronymBoundary = prev.isUppercase && (next?.isLowercase ?? false)
                if prevIsLowerOrDigit || acronymBoundary { spaced.append("_") }
            }
            spaced.append(ch)
        }
        var s = spaced.lowercased()
        // Replace separators with underscore.
        s = s.replacingOccurrences(of: " ", with: "_")
             .replacingOccurrences(of: "-", with: "_")
        // Keep only [a-z0-9_].
        s = String(s.unicodeScalars.filter { ("a"..."z").contains(Character($0)) || ("0"..."9").contains(Character($0)) || $0 == "_" })
        // Collapse repeated underscores, trim edges.
        while s.contains("__") { s = s.replacingOccurrences(of: "__", with: "_") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        // Must start with a letter.
        guard let first = s.first, first.isLetter else { return nil }
        // Bound length.
        if s.count > 48 { s = String(s.prefix(48)) }
        return s
    }

    static func deriveLabel(from key: String) -> String {
        let words = key.replacingOccurrences(of: "_", with: " ")
        guard let first = words.first else { return key }
        return first.uppercased() + words.dropFirst()
    }

    static func isMultiline(_ key: String) -> Bool {
        let needles = ["code", "error", "snippet", "diff", "log", "context", "text", "description", "details", "stack", "output"]
        let lower = key.lowercased()
        return needles.contains { lower.contains($0) }
    }

    static func deriveTitle(from body: String) -> String {
        let firstLine = body.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !firstLine.isEmpty { return String(firstLine.prefix(60)) }
        return "Composed Prompt"
    }

    private static func trimmedNonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
