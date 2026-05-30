// PromptEditorView.swift — DoomCoder Companion (Tools)
// Create or edit a prompt template. Placeholders use {{key}} syntax; the detail
// view auto-generates fill-in fields for them. Includes one-tap Enhance.

import SwiftUI
import DoomCoderCore

struct PromptEditorView: View {
    let existing: Prompt?

    @Environment(\.dismiss) private var dismiss
    @State private var store = PromptStore.shared

    @State private var title: String
    @State private var category: PromptCategory
    @State private var bodyText: String
    @State private var tagsText: String
    @State private var showEnhance = false

    /// Optional callback; when provided, used instead of the default store write
    /// (lets other screens, e.g. Tasks, decide what to do with the saved prompt).
    var onSaved: ((Prompt) -> Void)?

    init(existing: Prompt?,
         seedTitle: String = "",
         seedBody: String = "",
         onSaved: ((Prompt) -> Void)? = nil) {
        self.existing = existing
        self.onSaved = onSaved
        _title = State(initialValue: existing?.title ?? seedTitle)
        _category = State(initialValue: existing?.category ?? .general)
        _bodyText = State(initialValue: existing?.body ?? seedBody)
        _tagsText = State(initialValue: (existing?.tags ?? []).joined(separator: ", "))
    }

    private var placeholders: [String] { Prompt.placeholderKeys(in: bodyText) }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("e.g. Refactor for readability", text: $title)
                }

                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(PromptCategory.allCases) { cat in
                            Label(cat.displayName, systemImage: cat.symbol).tag(cat)
                        }
                    }
                }

                Section {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 160)
                        .font(.callout)
                    Button {
                        showEnhance = true
                    } label: {
                        Label("Enhance with AI", systemImage: "sparkles")
                    }
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("Use {{double_braces}} for fill-in blanks, e.g. “Refactor this {{language}} code: {{code}}”. They become input fields automatically.")
                }

                if !placeholders.isEmpty {
                    Section("Detected fields") {
                        Text(placeholders.map { "{{\($0)}}" }.joined(separator: "  "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("comma, separated, tags", text: $tagsText)
                } header: {
                    Text("Tags")
                }
            }
            .navigationTitle(existing == nil ? "New Prompt" : "Edit Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave).fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showEnhance) {
                EnhanceView(initialText: bodyText) { improved in
                    bodyText = improved
                }
            }
        }
    }

    private func save() {
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var prompt = existing ?? Prompt(title: "", body: "")
        prompt.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt.category = category
        prompt.body = bodyText
        prompt.tags = tags

        if existing == nil {
            store.add(prompt)
        } else {
            store.update(prompt)
        }
        onSaved?(prompt)
        Haptics.success()
        dismiss()
    }
}
