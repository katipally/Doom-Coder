// NotesStore.swift — DoomCoder Companion (Tools)
// On-device store for the freeform Notes scratchpad. Local-only.

import Foundation
import Observation
import DoomCoderCore

@MainActor
@Observable
final class NotesStore {
    static let shared = NotesStore()

    private let fileName = "notes.json"
    private(set) var notes: [Note] = []

    private init() {
        notes = JSONFileStore.load([Note].self, from: fileName) ?? []
    }

    /// Re-reads notes from disk (drives pull-to-refresh).
    func reload() {
        notes = JSONFileStore.load([Note].self, from: fileName) ?? []
    }

    func filtered(search: String) -> [Note] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [Note]
        if query.isEmpty {
            base = notes
        } else {
            base = notes.filter { note in
                note.body.lowercased().contains(query)
                    || note.checklist.contains { $0.text.lowercased().contains(query) }
            }
        }
        // Pinned first, then most-recently updated.
        return base.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }

    func togglePin(_ note: Note) {
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[idx].isPinned.toggle()
        notes[idx].updatedAt = Date()
        persist()
    }

    /// Schedules (or reschedules) a reminder for the note and persists it.
    @discardableResult
    func setReminder(_ date: Date, for note: Note) async -> NoteReminderScheduler.ScheduleResult {
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else {
            return .failed("Note not found")
        }
        // Reuse an existing notification id so we don't leak scheduled requests.
        let id = notes[idx].reminder?.notificationID ?? UUID().uuidString
        let reminder = NoteReminder(date: date, isEnabled: true, notificationID: id)
        let result = await NoteReminderScheduler.schedule(reminder: reminder, noteTitle: notes[idx].title)
        if result == .scheduled {
            notes[idx].reminder = reminder
            notes[idx].updatedAt = Date()
            persist()
        }
        return result
    }

    func clearReminder(for note: Note) {
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else { return }
        if let id = notes[idx].reminder?.notificationID {
            NoteReminderScheduler.cancel(notificationID: id)
        }
        notes[idx].reminder = nil
        notes[idx].updatedAt = Date()
        persist()
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
        notes.removeAll { $0.isEffectivelyEmpty && $0.reminder == nil }
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
