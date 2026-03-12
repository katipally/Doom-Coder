import SwiftUI
import AppKit
import DoomCodeCore

// MARK: - MacNoteEditor
//
// Full editor for a single note: title, body, task checklist, and a local
// reminder (a local notification). Content (title/body/checklist)
// autosaves via `MacNotesStore.updateContent`; the reminder is set
// through the store's async scheduler so a stale content snapshot can
// never clobber it.
//
// macOS 26 polish: the `GroupBox` shells (Tasks, Reminder) are kept
// here for now (still fine inside a single-pane editor) but the
// inner content uses semantic fonts. The 8pt `RoundedRectangle` outline
// around the body editor was tightened to a 10pt continuous squircle.
struct MacNoteEditor: View {
    let noteID: UUID
    let store: MacNotesStore

    @State private var title = ""
    @State private var body_ = ""
    @State private var checklist: [NoteChecklistItem] = []
    @State private var newItem = ""

    // Reminder state (a primary feature, surfaced directly in the editor).
    @State private var hasReminder: Bool
    @State private var reminderDate: Date
    @State private var showDenied = false
    @State private var pastDate = false
    @State private var reminderTask: Task<Void, Never>?

    @FocusState private var focus: Field?
    private enum Field { case title, body }

    init(noteID: UUID, store: MacNotesStore) {
        self.noteID = noteID
        self.store = store
        let note = store.note(id: noteID)
        _title = State(initialValue: note?.titleText ?? "")
        _body_ = State(initialValue: note?.body ?? "")
        _checklist = State(initialValue: note?.checklist ?? [])
        _hasReminder = State(initialValue: note?.reminder?.isEnabled ?? false)
        _reminderDate = State(initialValue: note?.reminder?.date
            ?? (Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleField
                Divider()
                bodySection
                tasksSection
                reminderSection
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if title.isEmpty && body_.isEmpty && checklist.isEmpty { focus = .title }
        }
        .onDisappear { reminderTask?.cancel() }
        .alert("Reminders are turned off", isPresented: $showDenied) {
            Button("Open Settings") { openNotificationSettings() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Enable notifications for Doom Coder in System Settings to get note reminders.")
        }
    }

    private var titleField: some View {
        TextField("Title", text: $title)
            .textFieldStyle(.plain)
            .font(.title2.weight(.semibold))
            .focused($focus, equals: .title)
            .onChange(of: title) { _, _ in persist() }
            .onSubmit { focus = .body }
            .accessibilityLabel("Note title")
    }

    private var bodySection: some View {
        ZStack(alignment: .topLeading) {
            if body_.isEmpty {
                Text("Write your note…")
                    .foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 6)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            TextEditor(text: $body_)
                .font(.body).focused($focus, equals: .body)
                .scrollContentBackground(.hidden).padding(4)
                .frame(minHeight: 120, maxHeight: 240)
                .onChange(of: body_) { _, _ in persist() }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.quaternary)
        )
        .accessibilityLabel("Note body")
    }

    private var tasksSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if checklist.isEmpty {
                    Text("Add tasks to track to-dos inside this note.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach($checklist) { $item in
                    HStack(spacing: 8) {
                        Button { item.isDone.toggle(); persist() } label: {
                            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isDone ? .green : .secondary)
                                .symbolEffect(.bounce, value: item.isDone)
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .accessibilityLabel(item.isDone ? "Mark not done" : "Mark done")
                        TextField("Task", text: $item.text)
                            .textFieldStyle(.plain)
                            .strikethrough(item.isDone)
                            .onChange(of: item.text) { _, _ in persist() }
                        Button { removeItem(item.id) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove task")
                    }
                    .accessibilityElement(children: .combine)
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Add a task", text: $newItem)
                        .textFieldStyle(.plain)
                        .onSubmit(addItem)
                }
            }
            .padding(4)
        } label: {
            Label("Tasks", systemImage: "checklist")
        }
    }

    private var reminderSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { hasReminder },
                    set: { on in
                        hasReminder = on
                        pastDate = false
                        if on { scheduleReminder() }
                        else { reminderTask?.cancel(); store.clearReminder(for: noteID) }
                    }
                )) {
                    Label("Remind me", systemImage: "bell")
                }
                if hasReminder {
                    DatePicker("When", selection: $reminderDate, in: Date()...,
                               displayedComponents: [.date, .hourAndMinute])
                        .onChange(of: reminderDate) { _, _ in scheduleReminder() }
                }
                if pastDate {
                    Label("Pick a time in the future.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(hasReminder
                     ? "A local notification fires at the chosen time. Reminders stay on this Mac."
                     : "Get a local notification at a time you choose.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(4)
        } label: {
            Label("Reminder", systemImage: "bell.badge")
        }
    }

    private func addItem() {
        let t = newItem.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        checklist.append(NoteChecklistItem(id: UUID(), text: t, isDone: false))
        newItem = ""
        persist()
    }

    private func removeItem(_ id: UUID) {
        checklist.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        store.updateContent(id: noteID, title: title, body: body_, checklist: checklist)
    }

    /// Schedules the reminder, cancelling any in-flight attempt first. If the
    /// user toggled the reminder off while a schedule was in flight, the late
    /// success is undone so we never fire a notification they cancelled.
    private func scheduleReminder() {
        reminderTask?.cancel()
        let date = reminderDate
        reminderTask = Task { @MainActor in
            let result = await store.setReminder(date, for: noteID)
            guard !Task.isCancelled else { return }
            switch result {
            case .scheduled:
                pastDate = false
                if !hasReminder { store.clearReminder(for: noteID) }
            case .permissionDenied:
                hasReminder = false; showDenied = true
            case .dateInPast:
                pastDate = true
            case .failed:
                hasReminder = false
            }
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
