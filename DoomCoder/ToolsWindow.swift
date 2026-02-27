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
import UserNotifications
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

    func note(id: UUID) -> Note? { notes.first { $0.id == id } }

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

    /// Persists only the editable content fields, preserving store-owned fields
    /// (reminder, notificationID) so an editor's stale snapshot can never wipe a
    /// reminder set via `setReminder`/`togglePin`.
    func updateContent(id: UUID, body: String, checklist: [NoteChecklistItem]) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].body = body
        notes[i].checklist = checklist
        notes[i].updatedAt = Date()
        save()
    }

    func togglePin(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].isPinned.toggle(); notes[i].updatedAt = Date(); save()
    }

    /// Schedules (or reschedules) a reminder and persists it on success.
    @discardableResult
    func setReminder(_ date: Date, for id: UUID) async -> MacNoteReminderScheduler.ScheduleResult {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return .failed("Note not found") }
        let notificationID = notes[i].reminder?.notificationID ?? UUID().uuidString
        let reminder = NoteReminder(date: date, isEnabled: true, notificationID: notificationID)
        let result = await MacNoteReminderScheduler.schedule(reminder: reminder, noteTitle: notes[i].title)
        if result == .scheduled, let j = notes.firstIndex(where: { $0.id == id }) {
            notes[j].reminder = reminder
            notes[j].updatedAt = Date()
            save()
        }
        return result
    }

    func clearReminder(for id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        if let nid = notes[i].reminder?.notificationID {
            MacNoteReminderScheduler.cancel(notificationID: nid)
        }
        notes[i].reminder = nil
        notes[i].updatedAt = Date()
        save()
    }

    func delete(_ id: UUID) {
        if let nid = notes.first(where: { $0.id == id })?.reminder?.notificationID {
            MacNoteReminderScheduler.cancel(notificationID: nid)
        }
        notes.removeAll { $0.id == id }
        save()
    }

    /// Drops empty notes — but keeps any that still carry a reminder.
    func pruneEmpty() {
        let before = notes.count
        notes.removeAll { $0.isEffectivelyEmpty && $0.reminder == nil }
        if notes.count != before { save() }
    }
}

// MARK: - Mac note reminder scheduling (local notifications)

/// Schedules/cancels a single one-shot local notification per note reminder.
/// Notification permission is requested lazily — only when the user first sets a
/// reminder. The Mac app is LSUIElement, so the app delegate's `willPresent`
/// delegate is what makes these banners appear while the app is "foreground".
enum MacNoteReminderScheduler {
    enum ScheduleResult: Equatable {
        case scheduled
        case permissionDenied
        case dateInPast
        case failed(String)
    }

    static func schedule(reminder: NoteReminder, noteTitle: String) async -> ScheduleResult {
        // Require a small buffer so a just-passed minute doesn't silently no-op.
        guard reminder.date > Date().addingTimeInterval(5) else { return .dateInPast }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return .permissionDenied }
        case .denied:
            return .permissionDenied
        default:
            break
        }

        center.removePendingNotificationRequests(withIdentifiers: [reminder.notificationID])

        let content = UNMutableNotificationContent()
        content.title = "Note reminder"
        content.body = noteTitle.isEmpty ? "You set a reminder on a note." : noteTitle
        content.sound = .default
        content.userInfo = ["doomcoder.noteReminder": true]

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: reminder.date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: reminder.notificationID, content: content, trigger: trigger)

        do {
            try await center.add(request)
            return .scheduled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func cancel(notificationID: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationID])
    }
}

private enum MacClipboard {
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

// MARK: - Floating tool surfaces (Prompts / Notes / Settings)
//
// The old single sidebar "Tools" window is gone. Each toolkit surface now opens
// in its own standalone window that:
//   • floats above all apps, including full-screen Spaces,
//   • carries a real traffic-light close button (native titled scene),
//   • remembers its size/position across launches,
//   • can be open alongside the others (Prompts + Notes side-by-side).
// Closing a window only hides it; the SwiftUI scene + shared singleton stores
// keep the data, so reopening from the floating bar restores the prior state.

enum ToolSurface: String, CaseIterable {
    case prompts, notes, settings
    /// Matches the SwiftUI `Window(id:)` scene identifiers in DoomCoderApp.
    var windowID: String { rawValue }
}

/// Configures the host NSWindow of a SwiftUI scene to float above everything
/// (incl. full-screen apps) and to remember its frame. Applied once on appear.
struct FloatingWindowConfigurator: NSViewRepresentable {
    let autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            window.level = .floating
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName(autosaveName)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Opens tool surfaces and drives the floating bar's Minimize / restore.
@MainActor
enum ToolSurfaceManager {
    /// Surfaces hidden by the last Minimize, reopened when the bar returns.
    private(set) static var pendingRestore: [ToolSurface] = []

    static func open(_ surface: ToolSurface) {
        NSApp.activate()
        switch surface {
        case .prompts:  WindowOpener.open(.prompts)
        case .notes:    WindowOpener.open(.notes)
        case .settings: WindowOpener.open(.settings)
        }
    }

    static func visibleSurfaces() -> [ToolSurface] {
        ToolSurface.allCases.filter { surface in
            NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue == surface.windowID }
        }
    }

    /// Hides every open surface window, remembering them for the next restore.
    static func hideOpenSurfaces() {
        let open = visibleSurfaces()
        pendingRestore = open
        for surface in open {
            NSApp.windows.first { $0.identifier?.rawValue == surface.windowID }?.close()
        }
    }

    /// Reopens whatever Minimize last hid. Called when the bar is shown again.
    static func restorePendingSurfaces() {
        let toRestore = pendingRestore
        pendingRestore = []
        for surface in toRestore { open(surface) }
    }
}

// MARK: - Settings surface (General + AI), shown as a floating window

/// The Mac Settings window: native tabbed layout pairing General preferences
/// with full AI configuration (on-device / API key), at parity with iOS.
struct MacSettingsSurface: View {
    var body: some View {
        TabView {
            ConfigureSettingsPane(sleepManager: SleepManager.shared)
                .tabItem { Label("General", systemImage: "gear") }
            MacToolsSettingsPane()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(minWidth: 640, minHeight: 580)
    }
}


// MARK: - Prompts (Compose | Library, toolbar-driven, inspector)

/// macOS 26 prompt workspace. A segmented Compose | Library control switches
/// between a toolbar-driven draft editor (with a saved-drafts sidebar and an
/// inspector for AI status + metadata) and the shared curated prompt library.
/// The store is the source of truth; the editor owns only transient state, so
/// there are no stale-snapshot bugs. Writing and copying never require AI.
struct MacPromptsPane: View {
    @State private var store = MacPromptStore.shared
    @State private var coordinator = AIEngineCoordinator.shared
    @State private var showLibrary = false

    // Compose state.
    @State private var search = ""
    @State private var currentID: UUID?
    @State private var draft = ""
    @State private var preEnhance: String?
    @State private var isEnhancing = false
    @State private var enhanceTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var suppressSelectionHandling = false

    // Library state.
    @State private var librarySearch = ""

    @FocusState private var editorFocused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasContent: Bool { !trimmed.isEmpty }

    private var sortedDrafts: [Prompt] { store.prompts.sorted { $0.updatedAt > $1.updatedAt } }
    private var filteredDrafts: [Prompt] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sortedDrafts }
        return sortedDrafts.filter { $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q) }
    }

    var body: some View {
        NavigationSplitView {
            historySidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            composer
        }
        .navigationTitle("Prompts")
        .sheet(isPresented: $showLibrary) { librarySheet }
        .onChange(of: currentID) { old, new in handleSelectionChange(from: old, to: new) }
        .onDisappear {
            enhanceTask?.cancel()
            saveCurrentIfDirty(asID: currentID)
        }
    }

    // MARK: Library sheet

    /// The curated library, presented as a panel over the composer. Picking a
    /// prompt loads it into the editor and dismisses — mirrors the iOS flow.
    private var librarySheet: some View {
        NavigationStack {
            MacPromptLibraryView(search: $librarySearch, onOpen: openInComposer)
                .navigationTitle("Prompt Library")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showLibrary = false }
                    }
                }
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    // MARK: History sidebar (saved drafts)

    private var historySidebar: some View {
        Group {
            if filteredDrafts.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "No saved drafts" : "No matches",
                    systemImage: "tray",
                    description: Text(search.isEmpty
                        ? "Write a prompt, then Save to keep it here."
                        : "No drafts match “\(search)”."))
            } else {
                List(selection: $currentID) {
                    ForEach(filteredDrafts) { prompt in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(for: prompt.body)).font(.headline).lineLimit(1)
                            Text(prompt.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .tag(prompt.id)
                        .contextMenu {
                            Button(role: .destructive) { delete(prompt) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search drafts")
        // Primary actions live as proper buttons (not a cramped toolbar): a
        // pinned bottom bar, matching the friendly iOS layout.
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button { newDraft() } label: {
                    Label("New", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)

                Button { showLibrary = true } label: {
                    Label("Library", systemImage: "books.vertical")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Spacer()
            }
            .controlSize(.large)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    // MARK: Composer (editor + action buttons, iOS-style)

    private var composer: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Describe what you want your AI coding agent to do…")
                        .foregroundStyle(.secondary)
                        .padding(.top, 14).padding(.leading, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $draft)
                    .font(.body)
                    .focused($editorFocused)
                    .scrollContentBackground(.hidden)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityLabel("Prompt draft")

            Divider()
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

    /// Big, labeled action buttons in the body — the friendly iOS layout rather
    /// than icon buttons crammed into the window toolbar.
    private var actionBar: some View {
        VStack(spacing: 10) {
            Button { enhance() } label: {
                Label(isEnhancing ? "Enhancing…" : (preEnhance == nil ? "Enhance with AI" : "Enhance again"),
                      systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!hasContent || isEnhancing)

            HStack(spacing: 10) {
                Button { copyDraft() } label: {
                    Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!hasContent)

                Button { saveDraft() } label: {
                    Label(currentID == nil ? "Save" : "Update", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasContent)

                if preEnhance != nil {
                    Button { revertEnhance() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                    }
                }
            }
            .controlSize(.large)

            footerLine
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder
    private var footerLine: some View {
        HStack(spacing: 6) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Enhance rewrites your draft using \(coordinator.selection.displayName). Writing and copying never require AI — set up AI in Settings.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Library bridge

    private func openInComposer(_ prompt: Prompt) {
        saveCurrentIfDirty(asID: currentID)
        suppressSelectionHandling = true
        currentID = nil
        draft = prompt.body
        preEnhance = nil; errorMessage = nil; statusMessage = nil
        showLibrary = false
        editorFocused = true
    }

    // MARK: Actions

    private func enhance() {
        guard hasContent, !isEnhancing else { return }
        editorFocused = false
        errorMessage = nil; statusMessage = nil
        let snapshot = draft
        let capturedID = currentID
        isEnhancing = true
        enhanceTask?.cancel()
        enhanceTask = Task {
            let result = await coordinator.enhance(trimmed)
            await MainActor.run {
                isEnhancing = false
                guard !Task.isCancelled, currentID == capturedID, draft == snapshot else { return }
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

    private func delete(_ prompt: Prompt) {
        let wasCurrent = prompt.id == currentID
        store.delete(prompt)
        if wasCurrent {
            suppressSelectionHandling = true
            currentID = nil
            draft = ""
            preEnhance = nil
        }
    }

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

    /// Persists current editor content when it has unsaved changes — prevents
    /// silent data loss on switch/new/close.
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

// MARK: - Prompt Library (shared curated prompts)

/// Browses the shared `PromptLibrary`, grouped by category. Each row copies the
/// rendered prompt or opens its template in the composer. Works with zero setup.
private struct MacPromptLibraryView: View {
    @Binding var search: String
    let onOpen: (Prompt) -> Void

    @State private var flashMessage: String?

    private var groups: [(category: PromptCategory, prompts: [Prompt])] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return PromptLibrary.grouped().compactMap { group in
            guard !q.isEmpty else { return group }
            let matches = group.prompts.filter {
                $0.title.lowercased().contains(q)
                    || $0.body.lowercased().contains(q)
                    || $0.tags.contains { $0.lowercased().contains(q) }
            }
            return matches.isEmpty ? nil : (group.category, matches)
        }
    }

    var body: some View {
        List {
            if groups.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ForEach(groups, id: \.category) { group in
                    Section {
                        ForEach(group.prompts) { prompt in row(prompt) }
                    } header: {
                        Label(group.category.displayName, systemImage: group.category.symbol)
                    }
                }
            }
        }
        .listStyle(.inset)
        .searchable(text: $search, prompt: "Search prompts")
        .overlay(alignment: .bottom) {
            if let flashMessage {
                Label(flashMessage, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.green.opacity(0.4)))
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func row(_ prompt: Prompt) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(prompt.title).font(.headline)
                Text(prompt.render(values: [:]))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onOpen(prompt) }

            Button { copy(prompt) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help("Copy prompt")
                .accessibilityLabel("Copy “\(prompt.title)”")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button { copy(prompt) } label: { Label("Copy prompt", systemImage: "doc.on.doc") }
            Button { onOpen(prompt) } label: { Label("Open in composer", systemImage: "square.and.pencil") }
        }
    }

    private func copy(_ prompt: Prompt) {
        MacClipboard.copy(prompt.render(values: [:]))
        withAnimation { flashMessage = "Copied “\(prompt.title)”" }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { withAnimation { if flashMessage?.contains(prompt.title) == true { flashMessage = nil } } }
        }
    }
}





// MARK: - Notes (toolbar-driven editor + reminder/checklist inspector)

/// macOS 26 notes workspace: a list (search + new), a comfortable body editor
/// with inline checklist, and an inspector for reminder, pin, and metadata.
/// Selection is by `UUID` so store edits never desync the selection. Reminders
/// schedule a local notification and persist on this Mac only.
struct MacNotesPane: View {
    @State private var store = MacNotesStore.shared
    @State private var search = ""
    @State private var selectedID: UUID?
    // Inspector hidden by default; revealed via the toolbar or when creating a note.
    @State private var showInspector = false

    private var filtered: [Note] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.sorted }
        return store.sorted.filter {
            $0.body.lowercased().contains(q) || $0.checklist.contains { $0.text.lowercased().contains(q) }
        }
    }

    private var selectedNote: Note? { selectedID.flatMap { store.note(id: $0) } }

    var body: some View {
        NavigationSplitView {
            notesSidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            noteDetail
                .inspector(isPresented: $showInspector) {
                    Group {
                        if let note = selectedNote {
                            MacNoteInspector(note: note, store: store).id(note.id)
                        } else {
                            ContentUnavailableView("No note selected", systemImage: "sidebar.trailing")
                        }
                    }
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
                }
        }
        .navigationTitle("Notes")
        .onDisappear { store.pruneEmpty() }
    }

    // MARK: History sidebar (saved notes)

    private var notesSidebar: some View {
        list
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { create() } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    Spacer()
                }
                .controlSize(.large)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.bar)
            }
    }

    private var list: some View {
        Group {
            if filtered.isEmpty {
                ContentUnavailableView("No notes", systemImage: "note.text",
                    description: Text("Jot ideas, checklists, and reminders. Pin the important ones."))
            } else {
                List(selection: $selectedID) {
                    ForEach(filtered) { note in
                        NoteRow(note: note).tag(note.id)
                            .contextMenu {
                                Button { store.togglePin(note.id) } label: {
                                    Label(note.isPinned ? "Unpin" : "Pin",
                                          systemImage: note.isPinned ? "pin.slash" : "pin")
                                }
                                Button(role: .destructive) { delete(note.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search notes")
    }

    // MARK: Note detail (editor + body action buttons)

    @ViewBuilder
    private var noteDetail: some View {
        if let id = selectedID, store.note(id: id) != nil {
            VStack(spacing: 0) {
                MacNoteEditor(noteID: id, store: store).id(id)
                Divider()
                notesActionBar
            }
        } else {
            ContentUnavailableView {
                Label("Select a note", systemImage: "note.text")
            } description: {
                Text("Choose a note on the left, or create a new one.")
            } actions: {
                Button { create() } label: { Label("New note", systemImage: "square.and.pencil") }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Labeled action buttons in the body (not a cramped toolbar), iOS-style.
    @ViewBuilder
    private var notesActionBar: some View {
        if let note = selectedNote {
            let empty = note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            HStack(spacing: 10) {
                Button { store.togglePin(note.id) } label: {
                    Label(note.isPinned ? "Unpin" : "Pin",
                          systemImage: note.isPinned ? "pin.slash" : "pin")
                }
                Button { MacClipboard.copy(note.body) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(empty)
                Button { turnIntoPrompt(note) } label: {
                    Label("To Prompt", systemImage: "text.alignleft")
                }
                .disabled(empty)
                Button(role: .destructive) { delete(note.id) } label: {
                    Label("Delete", systemImage: "trash")
                }

                Spacer()

                Button { showInspector.toggle() } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help("Reminder, pin, and metadata")
            }
            .controlSize(.large)
            .padding(12)
            .background(.bar)
        }
    }

    private func create() {
        let note = store.newNote()
        selectedID = note.id
    }

    private func delete(_ id: UUID) {
        store.delete(id)
        if selectedID == id { selectedID = nil }
    }

    private func turnIntoPrompt(_ note: Note) {
        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let title = note.title
        MacPromptStore.shared.add(Prompt(title: title.isEmpty ? "Note" : title, category: .general, body: body))
    }
}

private struct NoteRow: View {
    let note: Note
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if note.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                        .accessibilityLabel("Pinned")
                }
                Text(note.title).font(.headline).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(note.updatedAt, style: .date)
                if !note.preview.isEmpty {
                    Text("·"); Text(note.preview).lineLimit(1)
                }
                if let r = note.reminder, r.isEnabled {
                    Text("·")
                    Label(r.date.formatted(date: .abbreviated, time: .shortened), systemImage: "bell.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(r.date > Date() ? .blue : .secondary)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Body + inline checklist editor. Holds transient text/checklist state and
/// persists via `updateContent`, which preserves store-owned fields (reminder).
private struct MacNoteEditor: View {
    let noteID: UUID
    let store: MacNotesStore

    @State private var body_ = ""
    @State private var checklist: [NoteChecklistItem] = []
    @State private var newItem = ""
    @FocusState private var bodyFocused: Bool

    init(noteID: UUID, store: MacNotesStore) {
        self.noteID = noteID
        self.store = store
        let note = store.note(id: noteID)
        _body_ = State(initialValue: note?.body ?? "")
        _checklist = State(initialValue: note?.checklist ?? [])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let r = store.note(id: noteID)?.reminder, r.isEnabled {
                    Label("Reminder \(r.date.formatted(date: .abbreviated, time: .shortened))",
                          systemImage: "bell.fill")
                        .font(.caption).foregroundStyle(r.date > Date() ? .blue : .secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.blue.opacity(0.1), in: Capsule())
                }

                ZStack(alignment: .topLeading) {
                    if body_.isEmpty {
                        Text("Write your note…")
                            .foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 6)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    TextEditor(text: $body_)
                        .font(.body).focused($bodyFocused)
                        .scrollContentBackground(.hidden).padding(4)
                        .frame(minHeight: 220)
                        .onChange(of: body_) { _, _ in persist() }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityLabel("Note body")

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach($checklist) { $item in
                            HStack(spacing: 8) {
                                Button { item.isDone.toggle(); persist() } label: {
                                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(item.isDone ? .green : .secondary)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                                .accessibilityLabel(item.isDone ? "Mark not done" : "Mark done")
                                TextField("Item", text: $item.text)
                                    .textFieldStyle(.plain)
                                    .strikethrough(item.isDone)
                                    .onChange(of: item.text) { _, _ in persist() }
                            }
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle").foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            TextField("Add item", text: $newItem)
                                .textFieldStyle(.plain)
                                .onSubmit(addItem)
                        }
                    }
                    .padding(4)
                } label: {
                    Label("Checklist", systemImage: "checklist")
                }
            }
            .padding()
        }
        .onAppear { if body_.isEmpty && checklist.isEmpty { bodyFocused = true } }
    }

    private func addItem() {
        let t = newItem.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        checklist.append(NoteChecklistItem(id: UUID(), text: t, isDone: false))
        newItem = ""
        persist()
    }

    private func persist() {
        store.updateContent(id: noteID, body: body_, checklist: checklist)
    }
}

/// Inspector: reminder scheduling, pin, and metadata. Writes directly to the
/// store so a stale editor snapshot can never clobber the reminder.
private struct MacNoteInspector: View {
    let note: Note
    let store: MacNotesStore

    @State private var hasReminder: Bool
    @State private var reminderDate: Date
    @State private var showDenied = false
    @State private var pastDate = false

    init(note: Note, store: MacNotesStore) {
        self.note = note
        self.store = store
        _hasReminder = State(initialValue: note.reminder?.isEnabled ?? false)
        _reminderDate = State(initialValue: note.reminder?.date
            ?? (Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)))
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { hasReminder },
                    set: { on in
                        hasReminder = on
                        pastDate = false
                        if on { Task { await schedule() } }
                        else { store.clearReminder(for: note.id) }
                    }
                )) {
                    Label("Remind me", systemImage: "bell")
                }
                if hasReminder {
                    DatePicker("When", selection: $reminderDate, in: Date()...,
                               displayedComponents: [.date, .hourAndMinute])
                        .onChange(of: reminderDate) { _, _ in Task { await schedule() } }
                }
                if pastDate {
                    Label("Pick a time in the future.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Reminder")
            } footer: {
                Text(hasReminder
                     ? "A local notification fires at the chosen time. Reminders stay on this Mac."
                     : "Optional. Get a local notification at a time you choose.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Note") {
                Toggle(isOn: Binding(
                    get: { note.isPinned },
                    set: { _ in store.togglePin(note.id) }
                )) { Label("Pinned", systemImage: "pin") }
                LabeledContent("Created") { Text(note.createdAt, style: .date) }
                LabeledContent("Updated") { Text(note.updatedAt, style: .date) }
                if !note.checklist.isEmpty {
                    let done = note.checklist.filter(\.isDone).count
                    LabeledContent("Checklist") { Text("\(done)/\(note.checklist.count) done") }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Reminders are turned off", isPresented: $showDenied) {
            Button("Open Settings") { openNotificationSettings() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Enable notifications for DoomCoder in System Settings to get note reminders.")
        }
    }

    private func schedule() async {
        let result = await store.setReminder(reminderDate, for: note.id)
        switch result {
        case .scheduled:
            pastDate = false
        case .permissionDenied:
            hasReminder = false; showDenied = true
        case .dateInPast:
            pastDate = true
        case .failed:
            hasReminder = false
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
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
