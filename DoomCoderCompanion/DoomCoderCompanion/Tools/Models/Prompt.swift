// Prompt.swift — DoomCoder Companion (Tools)
// Local, on-device prompt-template model. Powers the standalone Prompt Library:
// curated starters + user-created prompts, with {{placeholder}} fill-in fields.
// 100% offline — no Mac, no iCloud, no account required.

import Foundation

/// A fill-in field inside a prompt template, identified by a `{{key}}` token in
/// the template body.
struct PromptField: Identifiable, Codable, Hashable {
    var id: UUID
    /// Token used in the body, e.g. `language` for `{{language}}`.
    var key: String
    /// Human label shown above the input, e.g. "Language".
    var label: String
    /// Placeholder hint shown inside the empty input.
    var hint: String
    /// Whether the input should be a multi-line editor (e.g. pasting code).
    var multiline: Bool

    init(id: UUID = UUID(), key: String, label: String, hint: String = "", multiline: Bool = false) {
        self.id = id
        self.key = key
        self.label = label
        self.hint = hint
        self.multiline = multiline
    }

    private enum CodingKeys: String, CodingKey { case key, label, hint, multiline }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        key = try c.decode(String.self, forKey: .key)
        label = try c.decode(String.self, forKey: .label)
        hint = try c.decodeIfPresent(String.self, forKey: .hint) ?? ""
        multiline = try c.decodeIfPresent(Bool.self, forKey: .multiline) ?? false
    }
}

/// A reusable prompt template.
struct Prompt: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var category: PromptCategory
    /// Template text containing `{{key}}` placeholders.
    var body: String
    var fields: [PromptField]
    var tags: [String]
    var isFavorite: Bool
    /// True for seeded starter prompts. Curated prompts can be duplicated but are
    /// not destroyed by "reset to defaults".
    var isCurated: Bool
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         title: String,
         category: PromptCategory = .general,
         body: String,
         fields: [PromptField] = [],
         tags: [String] = [],
         isFavorite: Bool = false,
         isCurated: Bool = false,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.category = category
        self.body = body
        self.fields = fields
        self.tags = tags
        self.isFavorite = isFavorite
        self.isCurated = isCurated
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Bundled curated JSON omits id/createdAt/updatedAt/isFavorite — synthesize them.
    private enum CodingKeys: String, CodingKey {
        case title, category, body, fields, tags, isFavorite, isCurated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        title = try c.decode(String.self, forKey: .title)
        category = try c.decodeIfPresent(PromptCategory.self, forKey: .category) ?? .general
        body = try c.decode(String.self, forKey: .body)
        fields = try c.decodeIfPresent([PromptField].self, forKey: .fields) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isCurated = try c.decodeIfPresent(Bool.self, forKey: .isCurated) ?? false
        createdAt = Date()
        updatedAt = Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: FullCodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(category, forKey: .category)
        try c.encode(body, forKey: .body)
        try c.encode(fields, forKey: .fields)
        try c.encode(tags, forKey: .tags)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(isCurated, forKey: .isCurated)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    private enum FullCodingKeys: String, CodingKey {
        case id, title, category, body, fields, tags, isFavorite, isCurated, createdAt, updatedAt
    }
}

extension Prompt {
    /// Renders the template by substituting `{{key}}` with the supplied values.
    /// Missing values are left as the bare label in brackets so the output is
    /// still usable when pasted.
    func render(values: [String: String]) -> String {
        var output = body
        let tokens = Prompt.placeholderKeys(in: body)
        for key in tokens {
            let replacement = values[key].flatMap { $0.isEmpty ? nil : $0 } ?? "[\(key)]"
            output = output.replacingOccurrences(of: "{{\(key)}}", with: replacement)
        }
        return output
    }

    /// Extracts the ordered, de-duplicated set of `{{key}}` tokens in a template.
    static func placeholderKeys(in template: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{\\s*([a-zA-Z0-9_]+)\\s*\\}\\}") else { return [] }
        let range = NSRange(template.startIndex..., in: template)
        var seen = Set<String>()
        var result: [String] = []
        regex.enumerateMatches(in: template, range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: template) else { return }
            let key = String(template[r])
            if seen.insert(key).inserted { result.append(key) }
        }
        return result
    }

    /// Builds fields for any placeholder tokens that lack an explicit field
    /// definition (used for user-authored prompts).
    func resolvedFields() -> [PromptField] {
        let keys = Prompt.placeholderKeys(in: body)
        return keys.map { key in
            if let existing = fields.first(where: { $0.key == key }) { return existing }
            let label = key.replacingOccurrences(of: "_", with: " ").capitalized
            let multiline = ["code", "error", "snippet", "diff", "log", "context", "text"]
                .contains { key.lowercased().contains($0) }
            return PromptField(key: key, label: label, multiline: multiline)
        }
    }
}

/// Top-level grouping for prompts. Drives the category filter chips.
enum PromptCategory: String, Codable, CaseIterable, Identifiable {
    case refactor, tests, debug, review, explain, git, docs, scaffold, general

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .refactor: return "Refactor"
        case .tests:    return "Tests"
        case .debug:    return "Debug"
        case .review:   return "Review"
        case .explain:  return "Explain"
        case .git:      return "Git"
        case .docs:     return "Docs"
        case .scaffold: return "Scaffold"
        case .general:  return "General"
        }
    }

    var symbol: String {
        switch self {
        case .refactor: return "wand.and.rays"
        case .tests:    return "checkmark.seal"
        case .debug:    return "ant"
        case .review:   return "eye"
        case .explain:  return "text.book.closed"
        case .git:      return "arrow.triangle.branch"
        case .docs:     return "doc.text"
        case .scaffold: return "square.stack.3d.up"
        case .general:  return "sparkles"
        }
    }
}
