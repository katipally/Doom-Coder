// AgentTask.swift — DoomCoder Companion (Tools)
// A lightweight, on-device "to hand to your agent" checklist item. Each task can
// be turned into a pre-filled prompt. Local only — no Mac required.

import Foundation

struct AgentTask: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    /// Optional free-text note with extra detail / context.
    var note: String
    var isDone: Bool
    var createdAt: Date

    init(id: UUID = UUID(),
         title: String,
         note: String = "",
         isDone: Bool = false,
         createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.note = note
        self.isDone = isDone
        self.createdAt = createdAt
    }
}
