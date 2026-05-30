// NotesView.swift — DoomCoder Companion (Tools)
// A freeform scratchpad: jot ideas or paste agent output. Create/edit/delete,
// autosave, search. Fully on-device.

import SwiftUI

struct NotesView: View {
    @State private var store = NotesStore.shared
    @State private var search = ""
    @State private var openNote: Note?

    private var visible: [Note] { store.filtered(search: search) }

    var body: some View {
        Group {
            if store.notes.isEmpty {
                ToolEmptyState(
                    symbol: "note.text",
                    title: "No Notes",
                    message: "Capture ideas, snippets, or anything your agent gives you.",
                    actionTitle: "New Note"
                ) { create() }
            } else {
                list
            }
        }
        .navigationTitle("Notes")
        .searchable(text: $search, prompt: "Search notes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { create() } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New note")
            }
        }
        .sheet(item: $openNote, onDismiss: { store.pruneEmpty() }) { note in
            NoteEditorView(note: note)
        }
    }

    private var list: some View {
        List {
            if visible.isEmpty {
                Text("No notes match your search.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visible) { note in
                    Button { openNote = note } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(note.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(note.updatedAt, style: .date)
                                if !note.preview.isEmpty {
                                    Text("·")
                                    Text(note.preview).lineLimit(1)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            store.delete(note)
                            Haptics.warning()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func create() {
        let note = store.create()
        Haptics.tap()
        openNote = note
    }
}

// MARK: - Editor (autosave)

private struct NoteEditorView: View {
    let note: Note
    @Environment(\.dismiss) private var dismiss
    @State private var store = NotesStore.shared
    @State private var text: String
    @FocusState private var focused: Bool

    init(note: Note) {
        self.note = note
        _text = State(initialValue: note.body)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .navigationTitle("Note")
                .navigationBarTitleDisplayMode(.inline)
                .onChange(of: text) { _, newValue in
                    var updated = note
                    updated.body = newValue
                    store.update(updated)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.fontWeight(.semibold)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        if !text.isEmpty {
                            CopyButton(text: text)
                        }
                    }
                }
                .onAppear { focused = true }
        }
    }
}
