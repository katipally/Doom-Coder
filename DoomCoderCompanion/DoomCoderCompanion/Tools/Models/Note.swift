// Note.swift — DoomCoder Companion (Tools)
// A freeform on-device scratchpad note. Local only — no Mac required.

import Foundation

struct Note: Identifiable, Codable, Hashable {
    var id: UUID
    var body: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         body: String = "",
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// First non-empty line, used as the list title.
    var title: String {
        let line = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? "New Note" : line
    }

    /// Remainder preview shown under the title in the list.
    var preview: String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > 1 else { return "" }
        return lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
