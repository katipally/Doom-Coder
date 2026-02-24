// NotesStore.swift — DoomCoder Companion (Tools)
// On-device store for the freeform Notes scratchpad. Local-only.

import Foundation
import Observation

@MainActor
@Observable
final class NotesStore {
    static let shared = NotesStore()

    private let fileName = "notes.json"
    private(set) var notes: [Note] = []

    private init() {
        notes = JSONFileStore.load([Note].self, from: fileName) ?? []
    }

    func filtered(search: String) -> [Note] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = query.isEmpty ? notes : notes.filter { $0.body.lowercased().contains(query) }
        return base.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func create() -> Note {
        let note = Note()
        notes.insert(note, at: 0)
        persist()
        return note
    }

    func update(_ note: Note) {
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var updated = note
        updated.updatedAt = Date()
        notes[idx] = updated
        persist()
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        persist()
    }

    func delete(at offsets: IndexSet, in visible: [Note]) {
        let ids = offsets.map { visible[$0].id }
        notes.removeAll { ids.contains($0.id) }
        persist()
    }

    /// Drops empty notes (e.g. created then dismissed without typing).
    func pruneEmpty() {
        let before = notes.count
        notes.removeAll { $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if notes.count != before { persist() }
    }

    func deleteAll() {
        notes.removeAll()
        persist()
    }

    private func persist() {
        JSONFileStore.save(notes, to: fileName)
    }
}
