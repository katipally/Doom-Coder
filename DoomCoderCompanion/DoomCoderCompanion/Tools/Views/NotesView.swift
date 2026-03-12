// NotesView.swift — DoomCoder Companion (Tools)
// Rich on-device notes: freeform body + inline checklist + a local reminder +
// pin + search. Autosaves. "Turn into a prompt" hands a note to the Composer-
// backed prompt library. Fully on-device; reminders use local notifications and
// only ask permission the first time one is set.

import SwiftUI
import DoomCoderCore

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
                    message: "Capture ideas, checklists, or anything your agent gives you — with reminders when you need them.",
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
                .matchedTransitionSource(id: "new-note", in: zoomNamespace)
            }
        }
        .sheet(item: $openNote, onDismiss: { store.pruneEmpty() }) { note in
            NoteEditorView(note: note)
                .navigationTransition(.zoom(sourceID: note.id, in: zoomNamespace))
                .presentationDetents([.medium, .large])
                .presentationContentInteraction(.automatic)
                .presentationDragIndicator(.visible)
        }
    }

    @Namespace private var zoomNamespace

    private var list: some View {
        List {
            if visible.isEmpty {
                Text("No notes match your search.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visible) { note in
                    Button { openNote = note } label: { NoteRow(note: note) }
                        .matchedTransitionSource(id: note.id, in: zoomNamespace)
                        .swipeActions(edge: .leading) {
                            Button {
                                store.togglePin(note)
                                Haptics.selection()
                            } label: {
                                Label(note.isPinned ? "Unpin" : "Pin",
                                      systemImage: note.isPinned ? "pin.slash" : "pin")
                            }
                            .tint(.orange)
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
        .refreshable { store.reload() }
    }

    private func create() {
        let note = store.create()
        Haptics.tap()
        openNote = note
    }
}

// MARK: - Row

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Pinned")
                }
                Text(note.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(note.updatedAt, style: .date)
                if !note.preview.isEmpty {
                    Text("·")
                    Text(note.preview).lineLimit(1)
                }
                if let reminder = note.reminder, reminder.isEnabled {
                    Text("·")
                    Label(reminder.date.formatted(date: .abbreviated, time: .shortened),
                          systemImage: "bell.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(reminder.date > Date() ? .blue : .secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor (autosave)

private struct NoteEditorView: View {
    let note: Note
    @Environment(\.dismiss) private var dismiss
    @State private var store = NotesStore.shared

    @State private var text: String
    @State private var checklist: [NoteChecklistItem]
    @State private var isPinned: Bool
    @State private var reminderDate: Date
    @State private var hasReminder: Bool
    @State private var showReminderDenied = false
    @State private var reminderPastDate = false
    @FocusState private var focusedField: Field?

    /// Focusable fields in the editor, so a single keyboard "Done" can dismiss
    /// whichever field is active (body or any checklist item).
    private enum Field: Hashable {
        case body
        case checklist(UUID)
    }

    init(note: Note) {
        self.note = note
        _text = State(initialValue: note.body)
        _checklist = State(initialValue: note.checklist)
        _isPinned = State(initialValue: note.isPinned)
        _hasReminder = State(initialValue: note.reminder?.isEnabled ?? false)
        _reminderDate = State(initialValue: note.reminder?.date ?? Self.defaultReminderDate())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120, maxHeight: 200)
                        .focused($focusedField, equals: .body)
                        .onChange(of: text) { _, _ in save() }
                } header: {
                    Text("Note")
                }

                checklistSection
                reminderSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            isPinned.toggle()
                            store.togglePin(note)
                            Haptics.selection()
                        } label: {
                            Label(isPinned ? "Unpin" : "Pin",
                                  systemImage: isPinned ? "pin.slash" : "pin")
                        }
                        Button { turnIntoPrompt() } label: {
                            Label("Turn into a prompt", systemImage: "text.alignleft")
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !text.isEmpty {
                            Button {
                                UIPasteboard.general.string = text
                                Haptics.success()
                            } label: {
                                Label("Copy note", systemImage: "doc.on.doc")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More options")
                }
                // Keyboard dismiss — appears in the native iOS keyboard accessory bar.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button { focusedField = nil } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                    .accessibilityLabel("Dismiss keyboard")
                }
            }
            .onAppear { if text.isEmpty && checklist.isEmpty { focusedField = .body } }
            .alert("Reminders are turned off", isPresented: $showReminderDenied) {
                Button("Open Settings") { openSystemSettings() }
                Button("Not now", role: .cancel) { }
            } message: {
                Text("Enable notifications for DoomCoder in Settings to get note reminders.")
            }
        }
    }

    // MARK: Checklist

    @ViewBuilder
    private var checklistSection: some View {
        Section("Checklist") {
            ForEach($checklist) { $item in
                HStack(spacing: 10) {
                    Button {
                        item.isDone.toggle()
                        save()
                        Haptics.selection()
                    } label: {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isDone ? .green : .secondary)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityLabel(item.isDone ? "Mark not done" : "Mark done")

                    TextField("Item", text: $item.text)
                        .focused($focusedField, equals: .checklist(item.id))
                        .strikethrough(item.isDone, color: .secondary)
                        .foregroundStyle(item.isDone ? .secondary : .primary)
                        .onChange(of: item.text) { _, _ in save() }
                }
            }
            .onDelete { offsets in
                checklist.remove(atOffsets: offsets)
                save()
            }

            Button {
                checklist.append(NoteChecklistItem())
                save()
            } label: {
                Label("Add item", systemImage: "plus.circle")
            }
        }
    }

    // MARK: Reminder

    @ViewBuilder
    private var reminderSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { hasReminder },
                set: { on in
                    hasReminder = on
                    if on { Task { await scheduleReminder() } }
                    else { store.clearReminder(for: note); Haptics.tap() }
                }
            )) {
                Label("Remind me", systemImage: "bell")
            }

            if hasReminder {
                DatePicker("When", selection: $reminderDate,
                           in: Date()...,
                           displayedComponents: [.date, .hourAndMinute])
                    .onChange(of: reminderDate) { _, _ in
                        reminderPastDate = false
                        Task { await scheduleReminder() }
                    }
                if reminderPastDate {
                    Label("Pick a time in the future.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } footer: {
            if hasReminder {
                Text("A local notification will fire at the chosen time. Reminders stay on this device.")
            } else {
                Text("Optional. Get a local notification at a time you choose.")
            }
        }
    }

    private func scheduleReminder() async {
        let result = await store.setReminder(reminderDate, for: note)
        switch result {
        case .scheduled:
            reminderPastDate = false
            Haptics.success()
        case .permissionDenied:
            hasReminder = false
            showReminderDenied = true
            Haptics.warning()
        case .dateInPast:
            reminderPastDate = true
            Haptics.warning()
        case .failed:
            hasReminder = false
            Haptics.warning()
        }
    }

    // MARK: Save / actions

    private func save() {
        // Start from the store's freshest copy so fields it owns (reminder,
        // notificationID) are preserved — otherwise autosave would clobber a
        // reminder set via setReminder/togglePin with this view's stale snapshot.
        var updated = store.notes.first(where: { $0.id == note.id }) ?? note
        updated.body = text
        updated.checklist = checklist
        updated.isPinned = isPinned
        store.update(updated)
    }

    private func turnIntoPrompt() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        Haptics.success()
        // Hand the note text to the Prompts tab, which opens a fresh refine chat
        // pre-filled with this text (it does not auto-send — the user can edit).
        dismiss()
        AppRouter.shared.composePrompt(seededWith: body)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private static func defaultReminderDate() -> Date {
        Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
    }
}
