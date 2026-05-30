// ToolsWindow.swift — DoomCoder (macOS)
// A dedicated sidebar window that brings the standalone toolkit (Prompts /
// Notes / Settings) to the Mac, reusing the shared DoomCoderCore AI engine.
// Tools data is LOCAL-ONLY on this device — no sync.
//
// Design notes (per critique):
//  • Stores are long-lived singletons so they survive window close/reopen.
//  • JSON persistence is atomic; the directory is created on demand.
//  • A small window accessor brings the scene forward in this accessory app.

import SwiftUI
import AppKit
import DoomCoderCore

// MARK: - Local persistence (atomic, local-only)

private enum ToolsPaths {
    static func fileURL(_ name: String) -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        let folder = dir.appendingPathComponent("DoomCoderTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }
}

@MainActor
@Observable
final class MacPromptStore {
    static let shared = MacPromptStore()
    private let file = "prompts.json"

    private(set) var prompts: [Prompt] = []
    private(set) var loadError: String?

    private init() { load() }

    func load() {
        guard let url = ToolsPaths.fileURL(file), let data = try? Data(contentsOf: url) else { return }
        do { prompts = try JSONDecoder().decode([Prompt].self, from: data) }
        catch { loadError = "Couldn't read saved prompts." }
    }

    func save() {
        guard let url = ToolsPaths.fileURL(file) else { loadError = "No writable location."; return }
        do {
            let data = try JSONEncoder().encode(prompts)
            try data.write(to: url, options: .atomic)
            loadError = nil
        } catch { loadError = "Couldn't save prompts." }
    }

    func add(_ prompt: Prompt) { prompts.insert(prompt, at: 0); save() }
    func update(_ prompt: Prompt) {
        if let i = prompts.firstIndex(where: { $0.id == prompt.id }) {
            var p = prompt; p.updatedAt = Date(); prompts[i] = p; save()
        }
    }
    func delete(_ prompt: Prompt) { prompts.removeAll { $0.id == prompt.id }; save() }
}

@MainActor
@Observable
final class MacNotesStore {
    static let shared = MacNotesStore()
    private let file = "notes.json"

    private(set) var notes: [Note] = []
    private(set) var loadError: String?

    private init() { load() }

    var sorted: [Note] {
        notes.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }

    func load() {
        guard let url = ToolsPaths.fileURL(file), let data = try? Data(contentsOf: url) else { return }
        do { notes = try JSONDecoder().decode([Note].self, from: data) }
        catch { loadError = "Couldn't read saved notes." }
    }

    func save() {
        guard let url = ToolsPaths.fileURL(file) else { loadError = "No writable location."; return }
        do {
            let data = try JSONEncoder().encode(notes)
            try data.write(to: url, options: .atomic)
            loadError = nil
        } catch { loadError = "Couldn't save notes." }
    }

    @discardableResult
    func newNote() -> Note {
        let note = Note()
        notes.insert(note, at: 0); save()
        return note
    }
    func update(_ note: Note) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) {
            var n = note; n.updatedAt = Date(); notes[i] = n; save()
        }
    }
    func togglePin(_ note: Note) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) {
            notes[i].isPinned.toggle(); notes[i].updatedAt = Date(); save()
        }
    }
    func delete(_ note: Note) { notes.removeAll { $0.id == note.id }; save() }
    func pruneEmpty() { notes.removeAll { $0.isEffectivelyEmpty }; save() }
}

private enum MacClipboard {
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

// MARK: - Window focus accessor (brings the scene forward reliably)

private struct WindowFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            v.window?.makeKeyAndOrderFront(nil)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Root

enum ToolsSection: String, CaseIterable, Identifiable, Hashable {
    case prompts, notes, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .prompts: return "Prompts"
        case .notes: return "Notes"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .prompts: return "sparkles"
        case .notes: return "note.text"
        case .settings: return "gearshape"
        }
    }
}

struct ToolsRootView: View {
    @State private var selection: ToolsSection? = .prompts

    var body: some View {
        NavigationSplitView {
            List(ToolsSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.symbol)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .navigationTitle("DoomCoder Tools")
        } detail: {
            switch selection ?? .prompts {
            case .prompts:   MacPromptsPane()
            case .notes:     MacNotesPane()
            case .settings:  MacToolsSettingsPane()
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(WindowFocus())
    }
}

// MARK: - Prompts (single-screen composer + saved drafts)

/// The Prompt Composer mirrors iOS: a freeform draft editor with an action bar
/// (Enhance-in-place / Copy / Save / Undo) and a saved-drafts sidebar. The store
/// is the source of truth; the editor owns only transient state so there are no
/// stale-snapshot bugs. Writing and copying never require AI.
struct MacPromptsPane: View {
    @State private var store = MacPromptStore.shared
    @State private var coordinator = AIEngineCoordinator.shared
    @State private var search = ""
    @State private var currentID: UUID?

    // Transient editor state (never a captured Prompt value).
    @State private var draft = ""
    @State private var preEnhance: String?
    @State private var isEnhancing = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var suppressSelectionHandling = false
    @FocusState private var editorFocused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasContent: Bool { !trimmed.isEmpty }

    private var sortedDrafts: [Prompt] {
        store.prompts.sorted { $0.updatedAt > $1.updatedAt }
    }
    private var filtered: [Prompt] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sortedDrafts }
        return sortedDrafts.filter {
            $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q)
        }
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 240, idealWidth: 300)
            composer.frame(minWidth: 440)
        }
        .navigationTitle("Prompts")
        .onChange(of: currentID) { old, new in handleSelectionChange(from: old, to: new) }
        .onDisappear { saveCurrentIfDirty(asID: currentID) }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search drafts", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button { newDraft() } label: { Image(systemName: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New draft")
            }
            .padding(8)
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "No saved drafts" : "No matches",
                    systemImage: "sparkles",
                    description: Text(search.isEmpty
                        ? "Write a prompt on the right, then Save it to keep it here."
                        : "No drafts match “\(search)”."))
            } else {
                List(filtered, selection: $currentID) { prompt in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(for: prompt.body)).font(.headline).lineLimit(1)
                        Text(prompt.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .tag(prompt.id)
                }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(hasContent ? Self.title(for: draft) : "New draft")
                    .font(.title3.bold())
                    .lineLimit(1)
                Spacer()
                if isEnhancing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Enhancing with \(coordinator.selection.displayName)…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Describe what you want your AI coding agent to do…")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8).padding(.leading, 6)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(.body)
                    .focused($editorFocused)
                    .scrollContentBackground(.hidden)
            }
            .frame(minHeight: 240)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .accessibilityLabel("Prompt draft")

            actionBar
            footer
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { enhance() } label: {
                Label(preEnhance == nil ? "Enhance with AI" : "Enhance again", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasContent || isEnhancing)

            Button { copyDraft() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!hasContent)

            Button { saveDraft() } label: {
                Label(currentID == nil ? "Save" : "Update", systemImage: "tray.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!hasContent)

            if preEnhance != nil {
                Button { revertEnhance() } label: {
                    Label("Undo enhance", systemImage: "arrow.uturn.backward")
                }
            }

            Spacer()

            if currentID != nil {
                Button(role: .destructive) { deleteCurrent() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        } else if let statusMessage {
            Label(statusMessage, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        } else {
            Text("Enhance rewrites your draft using \(coordinator.selection.displayName). Set up AI in Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func enhance() {
        guard hasContent, !isEnhancing else { return }
        editorFocused = false
        errorMessage = nil; statusMessage = nil
        let snapshot = draft
        let capturedID = currentID
        isEnhancing = true
        Task {
            let result = await coordinator.enhance(trimmed)
            await MainActor.run {
                isEnhancing = false
                // Ignore the result if the user switched drafts or edited while it ran.
                guard currentID == capturedID, draft == snapshot else { return }
                switch result {
                case .success(let improved, _):
                    preEnhance = snapshot
                    draft = improved
                case .failure(let f, _):
                    errorMessage = friendly(f)
                }
            }
        }
    }

    private func revertEnhance() {
        guard let original = preEnhance else { return }
        draft = original
        preEnhance = nil
    }

    private func copyDraft() {
        MacClipboard.copy(trimmed)
        flash("Copied to clipboard")
    }

    private func saveDraft() {
        guard hasContent else { return }
        if let id = currentID, var existing = store.prompts.first(where: { $0.id == id }) {
            existing.body = trimmed
            existing.title = Self.title(for: trimmed)
            store.update(existing)
            flash("Draft updated")
        } else {
            let prompt = Prompt(title: Self.title(for: trimmed), category: .general, body: trimmed)
            store.add(prompt)
            suppressSelectionHandling = true
            currentID = prompt.id
            flash("Draft saved")
        }
        preEnhance = nil
    }

    private func newDraft() {
        saveCurrentIfDirty(asID: currentID)
        suppressSelectionHandling = true
        currentID = nil
        draft = ""
        preEnhance = nil; errorMessage = nil; statusMessage = nil
        editorFocused = true
    }

    private func deleteCurrent() {
        guard let id = currentID, let prompt = store.prompts.first(where: { $0.id == id }) else { return }
        store.delete(prompt)
        suppressSelectionHandling = true
        currentID = nil
        draft = ""
        preEnhance = nil
    }

    /// Loads a newly-selected draft, auto-saving the previous editor content first.
    private func handleSelectionChange(from old: UUID?, to new: UUID?) {
        if suppressSelectionHandling { suppressSelectionHandling = false; return }
        saveCurrentIfDirty(asID: old)
        preEnhance = nil; errorMessage = nil; statusMessage = nil
        if let new, let prompt = store.prompts.first(where: { $0.id == new }) {
            draft = prompt.body
        } else {
            draft = ""
        }
    }

    /// Persists the current editor content to `id` (or as a new draft) when it
    /// has unsaved changes — prevents silent data loss on switch/new/close.
    private func saveCurrentIfDirty(asID id: UUID?) {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if let id, var existing = store.prompts.first(where: { $0.id == id }) {
            guard existing.body != body else { return }
            existing.body = body
            existing.title = Self.title(for: body)
            store.update(existing)
        } else if id == nil {
            let prompt = Prompt(title: Self.title(for: body), category: .general, body: body)
            store.add(prompt)
        }
    }

    private func flash(_ message: String) {
        statusMessage = message
        errorMessage = nil
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { if statusMessage == message { statusMessage = nil } }
        }
    }

    private func friendly(_ failure: AIFailure) -> String {
        switch failure {
        case .missingKey:
            return "No API key set. Add one in Settings, or switch to On-device."
        case .unavailable(let reason):
            return "\(reason.message) Choose “My API key” in Settings to use a provider instead."
        case .network, .provider, .rateLimited:
            return failure.message + " Your draft is unchanged — try again."
        default:
            return failure.message
        }
    }

    private static func title(for body: String) -> String {
        let firstLine = body
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let base = firstLine.isEmpty ? "Untitled draft" : firstLine
        return base.count > 60 ? String(base.prefix(60)) + "…" : base
    }
}

// MARK: - Notes

struct MacNotesPane: View {
    @State private var store = MacNotesStore.shared
    @State private var search = ""
    @State private var selected: Note?

    private var filtered: [Note] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.sorted }
        return store.sorted.filter {
            $0.body.lowercased().contains(q) || $0.checklist.contains { $0.text.lowercased().contains(q) }
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search notes", text: $search).textFieldStyle(.roundedBorder)
                    Button { selected = store.newNote() } label: { Image(systemName: "square.and.pencil") }
                        .help("New note")
                        .accessibilityLabel("New note")
                }
                .padding(8)
                Divider()
                if filtered.isEmpty {
                    ContentUnavailableView("No notes", systemImage: "note.text",
                        description: Text("Jot ideas, checklists, and snippets. Pin the important ones."))
                } else {
                    List(filtered, selection: $selected) { note in
                        HStack {
                            if note.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title).font(.headline).lineLimit(1)
                                Text(note.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(note)
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 280)

            Group {
                if let note = selected {
                    MacNoteEditor(note: note, store: store)
                        .id(note.id)
                } else {
                    ContentUnavailableView("Select a note", systemImage: "note.text")
                }
            }
            .frame(minWidth: 380)
        }
        .navigationTitle("Notes")
        .onDisappear { store.pruneEmpty() }
    }
}

private struct MacNoteEditor: View {
    @State var note: Note
    let store: MacNotesStore
    @State private var newItem = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button { store.togglePin(note); note.isPinned.toggle() } label: {
                        Label(note.isPinned ? "Pinned" : "Pin", systemImage: note.isPinned ? "pin.fill" : "pin")
                    }
                    Spacer()
                    Button { MacClipboard.copy(note.body) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button(role: .destructive) { store.delete(note) } label: { Image(systemName: "trash") }
                        .help("Delete note")
                        .accessibilityLabel("Delete note")
                }
                TextEditor(text: $note.body)
                    .font(.body)
                    .frame(minHeight: 200)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .onChange(of: note.body) { _, _ in store.update(note) }

                GroupBox("Checklist") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach($note.checklist) { $item in
                            HStack {
                                Button { item.isDone.toggle(); store.update(note) } label: {
                                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                }.buttonStyle(.plain)
                                .accessibilityLabel(item.isDone ? "Mark not done" : "Mark done")
                                TextField("Item", text: $item.text)
                                    .textFieldStyle(.plain)
                                    .strikethrough(item.isDone)
                                    .onChange(of: item.text) { _, _ in store.update(note) }
                            }
                        }
                        HStack {
                            Image(systemName: "plus.circle").foregroundStyle(.secondary)
                            TextField("Add item", text: $newItem)
                                .textFieldStyle(.plain)
                                .onSubmit {
                                    let t = newItem.trimmingCharacters(in: .whitespaces)
                                    guard !t.isEmpty else { return }
                                    note.checklist.append(NoteChecklistItem(id: UUID(), text: t, isDone: false))
                                    newItem = ""
                                    store.update(note)
                                }
                        }
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Settings (AI engine)

struct MacToolsSettingsPane: View {
    @State private var coordinator = AIEngineCoordinator.shared
    @State private var keyInput = ""
    @State private var keyTestState: KeyTestState = .idle
    @State private var appleReason: String?

    private enum KeyTestState: Equatable {
        case idle, testing, ok(Int), failed(String)
    }

    var body: some View {
        let _ = coordinator.revision   // re-render on key/model changes
        Form {
            Section("AI") {
                Picker("Mode", selection: $coordinator.selection) {
                    ForEach(AIEngineSelection.allCases) { Text($0.displayName).tag($0) }
                }
                .accessibilityLabel("AI mode")
                Text(coordinator.selection.detail).font(.caption).foregroundStyle(.secondary)
                if coordinator.selection == .appleOnDevice, let appleReason {
                    Label(appleReason, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            if coordinator.selection == .remoteKey {
                Section("Provider") {
                    Picker("Provider", selection: Binding(
                        get: { coordinator.provider },
                        set: { newProvider in
                            coordinator.provider = newProvider
                            keyTestState = .idle
                            Task { await coordinator.loadModelsIfNeeded(for: newProvider) }
                        }
                    )) {
                        ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
                    }

                    if coordinator.hasKey(for: coordinator.provider) {
                        savedKeyControls
                    } else {
                        SecureField(coordinator.provider.keyHint, text: $keyInput)
                        Button {
                            let entered = keyInput
                            keyInput = ""
                            coordinator.setKey(entered, for: coordinator.provider)
                            Task { await testKey() }   // auto-validate + fetch on save
                        } label: {
                            Label("Save & test key", systemImage: "key.fill")
                        }
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Link("Get a key", destination: coordinator.provider.consoleURL).font(.caption)

                    statusLine
                }
            }

            Section {
                Text("Prompts and notes are stored only on this Mac. Nothing is synced. On-device stays fully local; with “My API key”, your prompts are sent to the provider you choose over HTTPS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            appleReason = (await coordinator.appleAvailability())?.message
            if coordinator.selection == .remoteKey {
                await coordinator.loadModelsIfNeeded(for: coordinator.provider)
            }
        }
    }

    @ViewBuilder
    private var savedKeyControls: some View {
        LabeledContent("API key") {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
        }

        let models = coordinator.discoveredModels[coordinator.provider] ?? []
        if !models.isEmpty {
            Picker("Model", selection: Binding(
                get: {
                    let current = coordinator.selectedModel(for: coordinator.provider)
                    return models.contains(current) ? current : (models.first ?? current)
                },
                set: { coordinator.setSelectedModel($0, for: coordinator.provider) }
            )) {
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }
        } else if keyTestState == .testing {
            LabeledContent("Model") {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
            }
        } else {
            LabeledContent("Model") {
                Text(coordinator.selectedModel(for: coordinator.provider)).foregroundStyle(.secondary)
            }
        }

        HStack {
            Button { Task { await testKey() } } label: {
                Label("Test again", systemImage: "checkmark.shield")
            }
            .disabled(keyTestState == .testing)
            Button(role: .destructive) {
                coordinator.clearKey(for: coordinator.provider)
                keyTestState = .idle
            } label: {
                Label("Remove key", systemImage: "key.slash")
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch keyTestState {
        case .testing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Testing…") }
                .font(.caption).foregroundStyle(.secondary)
        case .ok(let n):
            Label("Key works — \(n) model\(n == 1 ? "" : "s") available", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    private func testKey() async {
        keyTestState = .testing
        let result = await coordinator.testKey(for: coordinator.provider)
        switch result {
        case .success(let ids): keyTestState = .ok(ids.count)
        case .failure(let f):   keyTestState = .failed(f.message)
        }
    }
}
