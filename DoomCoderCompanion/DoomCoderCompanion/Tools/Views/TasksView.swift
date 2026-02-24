// TasksView.swift — DoomCoder Companion (Tools)
// A checklist of things to hand your AI agent. Create, check off, reorder, delete,
// add an optional note — and turn any task into a pre-filled prompt. On-device.

import SwiftUI

struct TasksView: View {
    @State private var store = TaskStore.shared
    @State private var newTitle = ""
    @State private var editingTask: AgentTask?
    @State private var promptSeed: PromptSeed?
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        Group {
            if store.tasks.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Tasks")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !store.tasks.isEmpty {
                    Menu {
                        EditButton()
                        Button(role: .destructive) {
                            store.clearCompleted()
                            Haptics.tap()
                        } label: {
                            Label("Clear completed", systemImage: "checkmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $editingTask) { task in
            TaskEditorView(task: task)
        }
        .sheet(item: $promptSeed) { seed in
            PromptEditorView(existing: nil, seedTitle: seed.title, seedBody: seed.body) { _ in
                promptSeed = nil
            }
        }
    }

    private var emptyState: some View {
        VStack {
            ToolEmptyState(
                symbol: "checklist",
                title: "No Tasks",
                message: "Jot down what you want your agent to do. You can turn any task into a ready-to-paste prompt."
            )
            addBar
                .padding(.horizontal)
                .padding(.bottom)
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(store.tasks) { task in
                    TaskRow(task: task,
                            onToggle: { store.toggle(task); Haptics.selection() },
                            onTap: { editingTask = task })
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.delete(task)
                                Haptics.warning()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                makePrompt(from: task)
                            } label: {
                                Label("Make prompt", systemImage: "text.alignleft")
                            }
                            .tint(.purple)
                        }
                        .contextMenu {
                            Button { makePrompt(from: task) } label: {
                                Label("Make prompt", systemImage: "text.alignleft")
                            }
                            Button { editingTask = task } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                        }
                }
                .onMove { store.move(from: $0, to: $1) }
            } footer: {
                Text("Swipe right to turn a task into a prompt. Swipe left to delete.")
            }

            Section {
                addBar
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
        }
    }

    private var addBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            TextField("Add a task…", text: $newTitle)
                .focused($addFieldFocused)
                .submitLabel(.done)
                .onSubmit(addTask)
            if !newTitle.isEmpty {
                Button("Add", action: addTask).fontWeight(.semibold)
            }
        }
    }

    private func addTask() {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.add(AgentTask(title: trimmed))
        newTitle = ""
        Haptics.success()
        addFieldFocused = true
    }

    private func makePrompt(from task: AgentTask) {
        Haptics.tap()
        let body = task.note.isEmpty ? task.title : "\(task.title)\n\nContext:\n\(task.note)"
        promptSeed = PromptSeed(title: task.title, body: body)
    }

    struct PromptSeed: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }
}

// MARK: - Row

private struct TaskRow: View {
    let task: AgentTask
    let onToggle: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.isDone ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Mark not done" : "Mark done")

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.isDone, color: .secondary)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                if !task.note.isEmpty {
                    Text(task.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Editor

private struct TaskEditorView: View {
    let task: AgentTask
    @Environment(\.dismiss) private var dismiss
    @State private var store = TaskStore.shared
    @State private var title: String
    @State private var note: String

    init(task: AgentTask) {
        self.task = task
        _title = State(initialValue: task.title)
        _note = State(initialValue: task.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $title)
                }
                Section {
                    TextEditor(text: $note)
                        .frame(minHeight: 120)
                } header: {
                    Text("Note (optional)")
                } footer: {
                    Text("Add any context. It's included when you turn this task into a prompt.")
                }
            }
            .navigationTitle("Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = task
                        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.note = note
                        store.update(updated)
                        Haptics.success()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
