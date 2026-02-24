// ToolkitModels.swift — DoomCoderCore
// Shared, local-only toolkit models used by BOTH the macOS app and the iOS
// companion. These power the standalone Tools experience (Prompt Composer,
// Smart Notes). They are pure-Foundation, Codable & Sendable value types with
// NO CloudKit / iCloud coupling — Tools data lives only on the device that
// created it. Each app persists these as plain JSON in its own Application
// Support directory; nothing here is ever synced.

import Foundation

// MARK: - Prompts

/// A fill-in field inside a prompt template, identified by a `{{key}}` token in
/// the template body.
public struct PromptField: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Token used in the body, e.g. `language` for `{{language}}`.
    public var key: String
    /// Human label shown above the input, e.g. "Language".
    public var label: String
    /// Placeholder hint shown inside the empty input.
    public var hint: String
    /// Whether the input should be a multi-line editor (e.g. pasting code).
    public var multiline: Bool

    public init(id: UUID = UUID(), key: String, label: String, hint: String = "", multiline: Bool = false) {
        self.id = id
        self.key = key
        self.label = label
        self.hint = hint
        self.multiline = multiline
    }

    private enum CodingKeys: String, CodingKey { case key, label, hint, multiline }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        key = try c.decode(String.self, forKey: .key)
        label = try c.decode(String.self, forKey: .label)
        hint = try c.decodeIfPresent(String.self, forKey: .hint) ?? ""
        multiline = try c.decodeIfPresent(Bool.self, forKey: .multiline) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(label, forKey: .label)
        try c.encode(hint, forKey: .hint)
        try c.encode(multiline, forKey: .multiline)
    }
}

/// A reusable prompt template.
public struct Prompt: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var category: PromptCategory
    /// Template text containing `{{key}}` placeholders.
    public var body: String
    public var fields: [PromptField]
    public var tags: [String]
    public var isFavorite: Bool
    /// True for seeded starter prompts. Curated prompts can be duplicated but are
    /// not destroyed by "reset to defaults".
    public var isCurated: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(),
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
    public func render(values: [String: String]) -> String {
        var output = body
        let tokens = Prompt.placeholderKeys(in: body)
        for key in tokens {
            let replacement = values[key].flatMap { $0.isEmpty ? nil : $0 } ?? "[\(key)]"
            output = output.replacingOccurrences(of: "{{\(key)}}", with: replacement)
        }
        return output
    }

    /// Extracts the ordered, de-duplicated set of `{{key}}` tokens in a template.
    public static func placeholderKeys(in template: String) -> [String] {
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
    public func resolvedFields() -> [PromptField] {
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
public enum PromptCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case refactor, tests, debug, review, explain, git, docs, scaffold, general

    public var id: String { rawValue }

    public var displayName: String {
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

    /// SF Symbol name for the category chip.
    public var symbol: String {
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

// MARK: - Notes

/// A single checklist row inside a note.
public struct NoteChecklistItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var isDone: Bool

    public init(id: UUID = UUID(), text: String = "", isDone: Bool = false) {
        self.id = id
        self.text = text
        self.isDone = isDone
    }
}

/// A local reminder attached to a note. Backed by a single scheduled
/// `UNUserNotificationCenter` request whose identifier is `notificationID`.
public struct NoteReminder: Codable, Hashable, Sendable {
    public var date: Date
    public var isEnabled: Bool
    /// Stable identifier for the scheduled local notification request, so it can
    /// be cancelled/rescheduled deterministically.
    public var notificationID: String

    public init(date: Date, isEnabled: Bool = true, notificationID: String = UUID().uuidString) {
        self.date = date
        self.isEnabled = isEnabled
        self.notificationID = notificationID
    }
}

/// A rich on-device note: freeform body + optional inline checklist + optional
/// reminder + pin. Local only — never synced.
public struct Note: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var body: String
    public var checklist: [NoteChecklistItem]
    public var reminder: NoteReminder?
    public var isPinned: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                body: String = "",
                checklist: [NoteChecklistItem] = [],
                reminder: NoteReminder? = nil,
                isPinned: Bool = false,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.body = body
        self.checklist = checklist
        self.reminder = reminder
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, body, checklist, reminder, isPinned, createdAt, updatedAt
    }

    // Backward compatible: legacy notes.json had only id/body/createdAt/updatedAt.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        checklist = try c.decodeIfPresent([NoteChecklistItem].self, forKey: .checklist) ?? []
        reminder = try c.decodeIfPresent(NoteReminder.self, forKey: .reminder)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// First non-empty line, used as the list title.
    public var title: String {
        let line = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !line.isEmpty { return line }
        if let firstItem = checklist.first(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return firstItem.text.trimmingCharacters(in: .whitespaces)
        }
        return "New Note"
    }

    /// Remainder preview shown under the title in the list.
    public var preview: String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if lines.count > 1 {
            return lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        if !checklist.isEmpty {
            let done = checklist.filter(\.isDone).count
            return "\(done)/\(checklist.count) done"
        }
        return ""
    }

    /// True when the note has no body text and no non-empty checklist items.
    public var isEffectivelyEmpty: Bool {
        let emptyBody = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let emptyList = checklist.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        return emptyBody && emptyList
    }
}
