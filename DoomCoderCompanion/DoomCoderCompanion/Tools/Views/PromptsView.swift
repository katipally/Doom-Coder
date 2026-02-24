// PromptsView.swift — DoomCoder Companion (Tools)
// The Prompt Library: browse/search curated + user prompts by category, fill in
// template placeholders, and copy the result to paste into an AI coding agent.
// Full create / edit / delete / favorite. 100% on-device.

import SwiftUI
import DoomCoderCore

// MARK: - Library

struct PromptsView: View {
    @State private var store = PromptStore.shared
    @State private var search = ""
    @State private var category: PromptCategory?
    @State private var favoritesOnly = false
    @State private var editor: EditorTarget?
    @State private var showEnhance = false
    @State private var showComposer = false

    private var visible: [Prompt] {
        store.filtered(search: search, category: category, favoritesOnly: favoritesOnly)
    }

    var body: some View {
        Group {
            if store.prompts.isEmpty {
                ToolEmptyState(
                    symbol: "text.alignleft",
                    title: "No Prompts",
                    message: "Compose a new prompt from a plain description, or restore the curated examples.",
                    actionTitle: "Compose a Prompt",
                    action: { showComposer = true },
                    secondaryActionTitle: "Restore example prompts",
                    secondaryAction: {
                        store.restoreCuratedStarters()
                        Haptics.success()
                    }
                )
            } else {
                list
            }
        }
        .navigationTitle("Prompts")
        .searchable(text: $search, prompt: "Search prompts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showComposer = true
                } label: {
                    Label("Compose", systemImage: "wand.and.stars")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showComposer = true } label: {
                        Label("Compose a prompt", systemImage: "wand.and.stars")
                    }
                    Button { editor = .create } label: {
                        Label("New blank prompt", systemImage: "square.and.pencil")
                    }
                    Button { showEnhance = true } label: {
                        Label("Enhance an idea", systemImage: "sparkles")
                    }
                    Divider()
                    Toggle(isOn: $favoritesOnly) {
                        Label("Favorites only", systemImage: "star")
                    }
                    Button {
                        store.restoreCuratedStarters()
                        Haptics.success()
                    } label: {
                        Label("Restore examples", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showComposer) {
            ComposerView()
        }
        .sheet(item: $editor) { target in
            switch target {
            case .create:
                PromptEditorView(existing: nil)
            case .edit(let prompt):
                PromptEditorView(existing: prompt)
            }
        }
        .sheet(isPresented: $showEnhance) {
            EnhanceView { improved in
                let prompt = Prompt(title: "Enhanced prompt", body: improved)
                store.add(prompt)
                Haptics.success()
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        CategoryChip(title: "All", symbol: "square.grid.2x2",
                                     selected: category == nil) { category = nil }
                        ForEach(PromptCategory.allCases) { cat in
                            CategoryChip(title: cat.displayName, symbol: cat.symbol,
                                         selected: category == cat) {
                                category = (category == cat) ? nil : cat
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowBackground(Color.clear)
            }

            if visible.isEmpty {
                Section {
                    Text("No prompts match your filters.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(visible) { prompt in
                        NavigationLink {
                            PromptDetailView(promptID: prompt.id)
                        } label: {
                            PromptRow(prompt: prompt)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                store.toggleFavorite(prompt)
                                Haptics.selection()
                            } label: {
                                Label("Favorite", systemImage: prompt.isFavorite ? "star.slash" : "star")
                            }
                            .tint(.yellow)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.delete(prompt)
                                Haptics.warning()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                editor = .edit(prompt)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
    }

    enum EditorTarget: Identifiable {
        case create
        case edit(Prompt)
        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let p): return p.id.uuidString
            }
        }
    }
}

// MARK: - Row

private struct PromptRow: View {
    let prompt: Prompt

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: prompt.category.symbol)
                .foregroundStyle(.tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.title).font(.body.weight(.medium))
                Text(prompt.category.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if prompt.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Favorite")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CategoryChip: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.thinMaterial),
                            in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail (fill in + copy)

struct PromptDetailView: View {
    let promptID: UUID
    @State private var store = PromptStore.shared
    @State private var ai = AIEngineCoordinator.shared
    @State private var values: [String: String] = [:]
    @State private var editedBody = ""
    @State private var usingEditedBody = false
    @State private var isWorking = false
    @State private var notice: String?
    @State private var showEditor = false
    @State private var showSavedConfirmation = false

    private var prompt: Prompt? { store.prompts.first(where: { $0.id == promptID }) }

    var body: some View {
        Group {
            if let prompt {
                content(for: prompt)
            } else {
                ContentUnavailableView("Prompt deleted", systemImage: "trash")
            }
        }
    }

    private func rendered(for prompt: Prompt) -> String {
        usingEditedBody ? editedBody : prompt.render(values: values)
    }

    private func content(for prompt: Prompt) -> some View {
        let fields = prompt.resolvedFields()
        let finalText = rendered(for: prompt)
        return Form {
            if !fields.isEmpty {
                Section("Fill in") {
                    ForEach(fields) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.label).font(.caption).foregroundStyle(.secondary)
                            if field.multiline {
                                TextEditor(text: binding(for: field.key))
                                    .frame(minHeight: 80)
                                    .font(.callout)
                            } else {
                                TextField(field.hint.isEmpty ? field.label : field.hint,
                                          text: binding(for: field.key))
                            }
                        }
                    }
                }
            }

            Section {
                TextEditor(text: finalBinding(for: prompt))
                    .font(.callout)
                    .frame(minHeight: 180)
            } header: {
                Text("Prompt")
            } footer: {
                Text(fields.isEmpty
                     ? "Edit the prompt directly here, then enhance or copy it."
                     : "Fill the fields above, or edit the prompt directly here. Enhance and copy are right below.")
            }

            Section {
                CopyButton(text: finalText, title: "Copy prompt", prominent: true)
                Button {
                    Task { await enhance(prompt) }
                } label: {
                    HStack {
                        if isWorking { ProgressView().controlSize(.small) }
                        Label(isWorking ? "Enhancing…" : "Enhance with AI", systemImage: "sparkles")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
                if usingEditedBody {
                    Button {
                        saveEdits(prompt)
                    } label: {
                        Label(showSavedConfirmation ? "Saved" : "Save changes",
                              systemImage: showSavedConfirmation ? "checkmark" : "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        usingEditedBody = false
                        editedBody = ""
                        notice = nil
                        Haptics.tap()
                    } label: {
                        Label("Revert to template", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            } footer: {
                if let notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !prompt.tags.isEmpty {
                Section("Tags") {
                    Text(prompt.tags.map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(prompt.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        store.toggleFavorite(prompt)
                        Haptics.selection()
                    } label: {
                        Label(prompt.isFavorite ? "Unfavorite" : "Favorite",
                              systemImage: prompt.isFavorite ? "star.slash" : "star")
                    }
                    Button { showEditor = true } label: {
                        Label("Edit title & details", systemImage: "pencil")
                    }
                    Button {
                        _ = store.duplicate(prompt)
                        Haptics.success()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            PromptEditorView(existing: prompt)
        }
    }

    private func enhance(_ prompt: Prompt) async {
        isWorking = true; notice = nil
        defer { isWorking = false }
        let outcome = await ai.enhance(rendered(for: prompt))
        switch outcome {
        case .success(let improved, let tier):
            usingEditedBody = true
            editedBody = improved
            notice = "Enhanced with \(tier.displayName). Tap Save changes to keep it."
            Haptics.success()
        case .failure(let failure, _):
            notice = failure.message
            Haptics.warning()
        }
    }

    private func saveEdits(_ prompt: Prompt) {
        var updated = prompt
        updated.body = editedBody
        store.update(updated)
        usingEditedBody = false
        editedBody = ""
        notice = nil
        showSavedConfirmation = true
        Haptics.success()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            showSavedConfirmation = false
        }
    }

    private func finalBinding(for prompt: Prompt) -> Binding<String> {
        Binding(
            get: { usingEditedBody ? editedBody : prompt.render(values: values) },
            set: { newValue in
                usingEditedBody = true
                editedBody = newValue
            }
        )
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }
}
