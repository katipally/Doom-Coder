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
    case prompts, notes, settings, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .prompts: return "Prompts"
        case .notes: return "Notes"
        case .settings: return "Settings"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .prompts: return "sparkles"
        case .notes: return "note.text"
        case .settings: return "gearshape"
        case .about: return "info.circle"
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
            case .about:     AboutView()
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(WindowFocus())
    }
}

// MARK: - Prompts (Composer + library)

struct MacPromptsPane: View {
    @State private var store = MacPromptStore.shared
    @State private var coordinator = AIEngineCoordinator.shared
    @State private var search = ""
    @State private var selected: Prompt?
    @State private var showComposer = false

    private var filtered: [Prompt] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.prompts }
        return store.prompts.filter {
            $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search prompts", text: $search)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        showComposer = true
                    } label: { Label("Compose", systemImage: "plus") }
                }
                .padding(8)
                Divider()
                if filtered.isEmpty {
                    ContentUnavailableView("No prompts yet",
                        systemImage: "sparkles",
                        description: Text("Compose a reusable prompt — describe what you want and the built-in AI drafts a template with fill-in fields."))
                } else {
                    List(filtered, selection: $selected) { prompt in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prompt.title).font(.headline).lineLimit(1)
                            Text(prompt.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .tag(prompt)
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 300)

            Group {
                if let prompt = selected {
                    MacPromptDetail(prompt: prompt, store: store)
                } else {
                    ContentUnavailableView("Select a prompt", systemImage: "doc.text")
                }
            }
            .frame(minWidth: 380)
        }
        .navigationTitle("Prompts")
        .sheet(isPresented: $showComposer) {
            MacComposerView { newPrompt in
                store.add(newPrompt)
                selected = newPrompt
            }
        }
    }
}

private struct MacPromptDetail: View {
    let prompt: Prompt
    let store: MacPromptStore
    @State private var values: [String: String] = [:]
    @State private var copied = false

    private var rendered: String { prompt.render(values: values) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(prompt.title).font(.title2.bold())
                if !prompt.resolvedFields().isEmpty {
                    GroupBox("Fill in") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(prompt.resolvedFields()) { field in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(field.label).font(.caption).foregroundStyle(.secondary)
                                    TextField(field.hint, text: Binding(
                                        get: { values[field.key] ?? "" },
                                        set: { values[field.key] = $0 }), axis: .vertical)
                                        .textFieldStyle(.roundedBorder)
                                        .lineLimit(field.multiline ? 2...6 : 1...2)
                                }
                            }
                        }
                    }
                }
                GroupBox("Prompt") {
                    Text(rendered)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
                HStack {
                    Button {
                        MacClipboard.copy(rendered)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    Spacer()
                    Button(role: .destructive) { store.delete(prompt) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .padding()
        }
    }
}

struct MacComposerView: View {
    var onSave: (Prompt) -> Void
    @State private var coordinator = AIEngineCoordinator.shared
    @State private var intent = ""
    @State private var template: ComposedTemplate?
    @State private var bodyText = ""
    @State private var title = ""
    @State private var isWorking = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compose a prompt").font(.title2.bold())
            Text("Describe what you want to achieve. The AI drafts a reusable template with fill-in fields you can edit.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("e.g. Write thorough unit tests for a function", text: $intent, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            HStack {
                Button {
                    compose()
                } label: { Label("Draft with AI", systemImage: "sparkles") }
                .disabled(intent.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                if isWorking { ProgressView().controlSize(.small) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }

            if template != nil {
                Divider()
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                Text("Template body — edit freely; {{fields}} become fill-ins.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $bodyText)
                    .font(.callout.monospaced())
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { saveAndClose() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(template == nil || bodyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 560, height: 540)
    }

    private func compose() {
        isWorking = true; error = nil
        Task {
            let result = await coordinator.compose(intent: intent)
            await MainActor.run {
                isWorking = false
                switch result {
                case .success(let t, _):
                    template = t
                    title = t.title
                    bodyText = t.body
                case .failure(let f, _):
                    error = f.message
                }
            }
        }
    }

    private func saveAndClose() {
        guard let template else { return }
        var prompt = template.toPrompt()
        prompt.title = title.isEmpty ? template.title : title
        prompt.body = bodyText
        prompt.fields = prompt.resolvedFields()
        onSave(prompt)
        dismiss()
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
    @State private var testState: String?
    @State private var isTesting = false
    @State private var appleReason: String?

    var body: some View {
        Form {
            Section("AI engine") {
                Picker("Engine", selection: $coordinator.selection) {
                    ForEach(AIEngineSelection.allCases) { Text($0.displayName).tag($0) }
                }
                Text(coordinator.selection.detail).font(.caption).foregroundStyle(.secondary)
                if coordinator.selection == .appleOnDevice, let appleReason {
                    Label(appleReason, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            if coordinator.selection == .remoteKey {
                Section("Provider") {
                    Picker("Provider", selection: $coordinator.provider) {
                        ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
                    }
                    SecureField(coordinator.provider.keyHint, text: $keyInput)
                    HStack {
                        Button("Save key") {
                            coordinator.setKey(keyInput, for: coordinator.provider)
                            keyInput = ""
                        }
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Test & load models") { testKey() }
                            .disabled(!coordinator.hasKey(for: coordinator.provider) || isTesting)
                        if isTesting { ProgressView().controlSize(.small) }
                        if let testState { Text(testState).font(.caption).foregroundStyle(.secondary) }
                    }
                    Link("Get a key", destination: coordinator.provider.consoleURL).font(.caption)

                    let models = coordinator.discoveredModels[coordinator.provider] ?? []
                    if !models.isEmpty {
                        Picker("Model", selection: Binding(
                            get: { coordinator.selectedModel(for: coordinator.provider) },
                            set: { coordinator.setSelectedModel($0, for: coordinator.provider) })) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
            }

            Section {
                Text("Prompts and notes are stored only on this Mac. Nothing is synced. With “My API key”, your prompts are sent to the provider you choose over HTTPS; the other engines stay fully on-device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            appleReason = (await coordinator.appleAvailability())?.message
        }
    }

    private func testKey() {
        isTesting = true; testState = nil
        Task {
            let result = await coordinator.testKey(for: coordinator.provider)
            await MainActor.run {
                isTesting = false
                switch result {
                case .success(let ids): testState = "\(ids.count) models loaded"
                case .failure(let f): testState = f.message
                }
            }
        }
    }
}
