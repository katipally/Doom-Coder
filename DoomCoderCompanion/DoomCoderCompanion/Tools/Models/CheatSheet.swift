// CheatSheet.swift — DoomCoder Companion (Tools)
// Curated, bundled CLI reference for the AI coding tools DoomCoder supports.
// Read-only, fully offline. Decoded from Tools/Content/cheatsheets.json.

import Foundation

struct CheatSheet: Identifiable, Codable, Hashable {
    var id: String { tool }
    /// Display name, e.g. "Claude Code".
    var tool: String
    /// Optional bundled asset name for the tool icon.
    var iconAsset: String?
    var summary: String
    var sections: [CheatSheetSection]

    private enum CodingKeys: String, CodingKey { case tool, iconAsset, summary, sections }
}

struct CheatSheetSection: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var entries: [CheatSheetEntry]

    init(id: UUID = UUID(), title: String, entries: [CheatSheetEntry]) {
        self.id = id
        self.title = title
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case title, entries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        title = try c.decode(String.self, forKey: .title)
        entries = try c.decode([CheatSheetEntry].self, forKey: .entries)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(entries, forKey: .entries)
    }
}

struct CheatSheetEntry: Identifiable, Codable, Hashable {
    var id: UUID
    /// The command or flag, shown monospaced and copyable.
    var command: String
    /// What it does.
    var detail: String

    init(id: UUID = UUID(), command: String, detail: String) {
        self.id = id
        self.command = command
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey { case command, detail }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        command = try c.decode(String.self, forKey: .command)
        detail = try c.decode(String.self, forKey: .detail)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(command, forKey: .command)
        try c.encode(detail, forKey: .detail)
    }
}
