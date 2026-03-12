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
final class MacConversationStore {
    static let shared = MacConversationStore()
    private let file = "conversations.json"
    /// Old draft file from the pre-chat build. Removed on first launch (clean
    /// slate — no migration, matching iOS).
    private let legacyDraftFile = "prompts.json"

    private(set) var conversations: [Conversation] = []
    private(set) var loadError: String?
    /// Text handed off from Notes' "To Prompt". `MacPromptsPane` consumes it on
    /// appear: opens a fresh chat pre-filled with this text (no auto-send).
    var pendingSeed: String?

    private init() {
        if let url = ToolsPaths.fileURL(legacyDraftFile) { try? FileManager.default.removeItem(at: url) }
        load()
    }

    func load() {
        guard let url = ToolsPaths.fileURL(file), let data = try? Data(contentsOf: url) else { return }
        do { conversations = try JSONDecoder().decode([Conversation].self, from: data).filter { !$0.isEffectivelyEmpty } }
        catch { loadError = "Couldn't read saved prompts." }
    }

    var byRecent: [Conversation] { conversations.sorted { $0.updatedAt > $1.updatedAt } }

    func conversation(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }

    /// Inserts or updates a conversation, stamping `updatedAt`, and persists.
    /// Empty conversations stay in memory (active session) but never hit disk.
    func save(_ conversation: Conversation) {
        var updated = conversation
        updated.updatedAt = Date()
        if let i = conversations.firstIndex(where: { $0.id == updated.id }) {
            conversations[i] = updated
        } else {
            conversations.append(updated)
        }
        persist()
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].customTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[i].updatedAt = Date()
        persist()
    }

    func delete(_ id: UUID) { conversations.removeAll { $0.id == id }; persist() }
    func deleteAll() { conversations.removeAll(); persist() }

    private func persist() {
        guard let url = ToolsPaths.fileURL(file) else { loadError = "No writable location."; return }
        do {
            let data = try JSONEncoder().encode(conversations.filter { !$0.isEffectivelyEmpty })
            try data.write(to: url, options: .atomic)
            loadError = nil
        } catch { loadError = "Couldn't save prompts." }
    }
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
    /// reminder set via `setReminder`/`togglePin`. No-ops when nothing changed to
    /// avoid needless `updatedAt` churn (which would reorder the sorted list).
    func updateContent(id: UUID, title: String, body: String, checklist: [NoteChecklistItem]) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[i].titleText != title
            || notes[i].body != body
            || notes[i].checklist != checklist else { return }
        notes[i].titleText = title
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

enum MacClipboard {
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
    case prompts, notes
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

// MARK: - Prompts (Compose | Library, toolbar-driven, inspector)

/// macOS 26 prompt workspace, redesigned as a refine transcript that mirrors the
/// iOS Companion: a history sidebar of saved conversations, a transcript where the
/// user's rough requests appear as trailing glass bubbles and the AI streams back
/// a refined prompt rendered plain with a Copy button, and a bottom refine input.
/// Conversations auto-save locally and reopen to continue. Writing and copying
/// never require AI.
struct MacPromptsPane: View {
    @State private var store = MacConversationStore.shared
    @State private var coordinator = AIEngineCoordinator.shared

    /// The transcript currently on screen (live source of truth while open).
    @State private var active = Conversation()
    @State private var selectedID: UUID?

    @State private var input = ""
    @State private var isGenerating = false
    @State private var generationTask: Task<Void, Never>?
    /// IDs of the in-flight exchange, so Stop can discard it and restore input.
    @State private var inflightUserID: UUID?
    @State private var inflightAssistantID: UUID?
    /// Identifies the current generation so a stale task that unwinds late can't
    /// clobber `isGenerating` or message state for a newer one.
    @State private var generationID: UUID?

    @State private var search = ""
    @State private var showLibrary = false
    @State private var libSearch = ""
    @State private var renameTarget: Conversation?
    @State private var renameText = ""
    @State private var pendingEditID: UUID?

    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmedInput.isEmpty && !isGenerating }
    /// True when the bar is completely idle: empty, unfocused, not generating.
    private var isIdle: Bool { input.isEmpty && !inputFocused && !isGenerating }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(isPresented: $showLibrary) { librarySheet }
        .alert("Rename conversation", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let target = renameTarget {
                    store.rename(target.id, to: renameText)
                    if active.id == target.id {
                        active.customTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Discard later messages?", isPresented: Binding(
            get: { pendingEditID != nil },
            set: { if !$0 { pendingEditID = nil } }
        )) {
            Button("Edit & discard", role: .destructive) {
                if let id = pendingEditID { performEdit(id) }
                pendingEditID = nil
            }
            Button("Cancel", role: .cancel) { pendingEditID = nil }
        } message: {
            Text("Editing this message removes the messages that came after it.")
        }
        .onAppear(perform: consumePendingSeed)
        .onChange(of: store.pendingSeed) { _, _ in consumePendingSeed() }
    }

    // MARK: - Sidebar (history)

    private var visibleConversations: [Conversation] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.byRecent }
        return store.byRecent.filter {
            $0.displayTitle.lowercased().contains(q) || $0.preview.lowercased().contains(q)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Group {
                if store.byRecent.isEmpty {
                    ContentUnavailableView(
                        "No history yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Your refined prompts save here automatically.")
                    )
                } else if visibleConversations.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    List(selection: $selectedID) {
                        ForEach(visibleConversations) { conversation in
                            historyRow(conversation)
                                .tag(conversation.id)
                                .contextMenu {
                                    Button {
                                        renameText = conversation.displayTitle
                                        renameTarget = conversation
                                    } label: { Label("Rename", systemImage: "pencil") }
                                    Button(role: .destructive) {
                                        deleteConversation(conversation.id)
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 240)
        .searchable(text: $search, placement: .sidebar, prompt: "Search history")
        .navigationTitle("Prompts")
        .toolbar {
            ToolbarItem {
                Button { libSearch = ""; showLibrary = true } label: {
                    Label("Library", systemImage: "books.vertical")
                }
                .help("Prompt library")
            }
            ToolbarItem {
                Button { newChat() } label: { Label("New chat", systemImage: "square.and.pencil") }
                    .disabled(active.messages.isEmpty && !isGenerating)
                    .help("New chat")
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .onChange(of: selectedID) { _, newValue in
            guard let id = newValue, id != active.id,
                  let conversation = store.conversation(id) else { return }
            open(conversation)
        }
    }

    private func historyRow(_ conversation: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(conversation.displayTitle)
                .font(.headline)
                .lineLimit(1)
            if !conversation.preview.isEmpty {
                Text(conversation.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(conversation.updatedAt, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail (transcript + input)

    private var detail: some View {
        VStack(spacing: 0) {
            transcript
            inputBar
        }
        .frame(minWidth: 420)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if active.messages.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(active.messages) { message in
                            MacMessageView(
                                message: message,
                                onCopy: { copy(message) },
                                onRetry: { retry(message.id) },
                                onEdit: { requestEdit(message.id) }
                            )
                            .id(message.id)
                        }
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
            .onChange(of: active.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: streamingSignature) { _, _ in scrollToBottom(proxy) }
        }
    }

    private var streamingSignature: Int {
        guard let id = inflightAssistantID,
              let msg = active.messages.first(where: { $0.id == id }) else { return 0 }
        return msg.text.count
    }

    private var bottomAnchor: String { "transcript-bottom" }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !active.messages.isEmpty else { return }
        if reduceMotion {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("Refine a prompt")
                    .font(.title2.weight(.semibold))
                Text("Describe what you want your AI coding agent to do. I'll rewrite it into a clear, structured prompt you can copy.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 420)

            if !quickStarts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Try one")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(quickStarts) { prompt in
                        Button {
                            input = prompt.body
                            inputFocused = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: prompt.category.symbol)
                                    .font(.footnote)
                                    .foregroundStyle(.tint)
                                Text(prompt.title)
                                    .font(.subheadline)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 420)
            }
        }
        .padding(32)
    }

    private var quickStarts: [Prompt] {
        PromptLibrary.grouped().prefix(4).compactMap { $0.prompts.first }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 8) {
            if showSetupBanner { setupBanner }
            HStack(alignment: .bottom, spacing: 0) {
                TextField("Describe your prompt…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .padding(.leading, 14)
                    .padding(.vertical, 10)
                    .padding(.trailing, 4)

                // Trailing action — fixed frame keeps the container stable.
                Group {
                    if isGenerating {
                        Button { stop() } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(.red.gradient, in: .circle)
                        }
                        .help("Stop generating")
                    } else if canSend {
                        Button { send() } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background {
                                    Circle().fill(AnyShapeStyle(Color.accentColor.gradient))
                                }
                        }
                        .help("Refine prompt")
                    } else {
                        Color.clear.frame(width: 28, height: 28)
                    }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .padding(.bottom, 6)
            }
            // Fixed corner radius — stays a consistent rounded rectangle as the
            // field grows, never distorting into a more circular capsule shape.
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            // Apple Intelligence-style rainbow aurora glow while the bar is idle.
            .overlay {
                RainbowIdleGlow(cornerRadius: 20)
                    .opacity(isIdle ? 1 : 0)
                    .animation(.easeInOut(duration: 0.5), value: isIdle)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var showSetupBanner: Bool {
        coordinator.selection == .remoteKey && !coordinator.hasKeyForCurrentProvider
    }

    private var setupBanner: some View {
        Button {
            WindowOpener.openSettings()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").font(.footnote)
                Text("Add an API key in Settings, or switch to On-device.")
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Library sheet

    private var librarySheet: some View {
        NavigationStack {
            MacPromptLibraryView(search: $libSearch) { prompt in
                input = prompt.body
                showLibrary = false
                inputFocused = true
            }
            .navigationTitle("Prompt Library")
            .frame(minWidth: 460, idealHeight: 580, maxHeight: 680)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showLibrary = false }
                }
            }
        }
    }

    // MARK: - Generation

    private func send() {
        let text = trimmedInput
        guard !text.isEmpty, !isGenerating else { return }
        inputFocused = false
        let userMsg = ChatMessage(role: .user, text: text)
        let assistantMsg = ChatMessage(role: .assistant, tier: coordinator.activeTier, status: .streaming)
        active.messages.append(userMsg)
        active.messages.append(assistantMsg)
        inflightUserID = userMsg.id
        inflightAssistantID = assistantMsg.id
        input = ""
        isGenerating = true
        persistActive()
        if selectedID != active.id { selectedID = active.id }
        let convID = active.id
        let assistantID = assistantMsg.id
        let token = UUID()
        generationID = token
        generationTask = Task { await runGeneration(conversationID: convID, assistantID: assistantID, token: token) }
    }

    @MainActor
    private func runGeneration(conversationID: UUID, assistantID: UUID, token: UUID) async {
        defer { if generationID == token { isGenerating = false; generationID = nil } }
        let transcript = active.engineTranscript()
        func isCurrent() -> Bool { generationID == token && active.id == conversationID }
        do {
            for try await chunk in coordinator.stream(transcript: transcript) {
                if Task.isCancelled { return }
                guard isCurrent() else { return }
                updateMessage(assistantID) { $0.text = chunk; $0.status = .streaming }
            }
            if Task.isCancelled { return }
            guard isCurrent() else { return }
            updateMessage(assistantID) { m in
                let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty {
                    m.status = .failed
                    m.errorText = "The AI returned an empty response. Try again."
                } else {
                    m.text = t
                    m.status = .complete
                }
            }
            clearInflight()
            persistActive()
        } catch let failure as AIFailure {
            if case .cancelled = failure { return }
            guard isCurrent() else { return }
            updateMessage(assistantID) { m in
                m.status = .failed
                m.errorText = friendly(failure)
            }
            clearInflight()
            persistActive()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent() else { return }
            updateMessage(assistantID) { m in
                m.status = .failed
                m.errorText = error.localizedDescription
            }
            clearInflight()
            persistActive()
        }
    }

    private func stop() {
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        isGenerating = false
        if let aID = inflightAssistantID {
            active.messages.removeAll { $0.id == aID }
        }
        if let uID = inflightUserID,
           let restored = active.messages.first(where: { $0.id == uID })?.text {
            active.messages.removeAll { $0.id == uID }
            input = restored
        }
        clearInflight()
        persistActive()
        inputFocused = true
    }

    private func retry(_ assistantID: UUID) {
        guard !isGenerating else { return }
        guard let idx = active.messages.firstIndex(where: { $0.id == assistantID }),
              active.messages[idx].role == .assistant else { return }
        active.messages.remove(at: idx)
        let assistantMsg = ChatMessage(role: .assistant, tier: coordinator.activeTier, status: .streaming)
        active.messages.append(assistantMsg)
        inflightUserID = nil
        inflightAssistantID = assistantMsg.id
        isGenerating = true
        persistActive()
        let convID = active.id
        let newID = assistantMsg.id
        let token = UUID()
        generationID = token
        generationTask = Task { await runGeneration(conversationID: convID, assistantID: newID, token: token) }
    }

    // MARK: - Edit & resend

    private func requestEdit(_ userID: UUID) {
        guard !isGenerating else { return }
        guard let idx = active.messages.firstIndex(where: { $0.id == userID }) else { return }
        let laterUserExists = active.messages[(idx + 1)...].contains { $0.role == .user }
        if laterUserExists {
            pendingEditID = userID
        } else {
            performEdit(userID)
        }
    }

    private func performEdit(_ userID: UUID) {
        guard let idx = active.messages.firstIndex(where: { $0.id == userID }) else { return }
        let text = active.messages[idx].text
        active.messages.removeSubrange(idx...)
        input = text
        clearInflight()
        persistActive()
        inputFocused = true
    }

    // MARK: - Conversation lifecycle

    private func newChat() {
        cancelInFlight()
        saveActiveIfNeeded()
        active = Conversation()
        selectedID = nil
        input = ""
        inputFocused = true
    }

    private func open(_ conversation: Conversation) {
        cancelInFlight()
        saveActiveIfNeeded()
        active = conversation
        selectedID = conversation.id
        input = ""
        inputFocused = false
    }

    private func deleteConversation(_ id: UUID) {
        store.delete(id)
        if active.id == id {
            cancelInFlight()
            active = Conversation()
            selectedID = nil
            input = ""
        }
    }

    private func consumePendingSeed() {
        guard let seed = store.pendingSeed else { return }
        store.pendingSeed = nil
        cancelInFlight()
        saveActiveIfNeeded()
        active = Conversation()
        selectedID = nil
        input = seed
        inputFocused = true
    }

    // MARK: - Helpers

    private func updateMessage(_ id: UUID, _ transform: (inout ChatMessage) -> Void) {
        guard let idx = active.messages.firstIndex(where: { $0.id == id }) else { return }
        transform(&active.messages[idx])
    }

    private func persistActive() {
        guard !active.isEffectivelyEmpty else { return }
        store.save(active)
    }

    private func saveActiveIfNeeded() {
        guard !active.isEffectivelyEmpty else { return }
        store.save(active)
    }

    private func cancelInFlight() {
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        isGenerating = false
        // Normalize a placeholder that was mid-stream so the saved transcript stays
        // retryable rather than frozen at "Refining…" with no live task.
        if let aID = inflightAssistantID {
            updateMessage(aID) { m in
                if m.status == .streaming {
                    m.status = .failed
                    m.errorText = "Generation was interrupted. Tap Retry to continue."
                }
            }
        }
        clearInflight()
    }

    private func clearInflight() {
        inflightUserID = nil
        inflightAssistantID = nil
    }

    private func copy(_ message: ChatMessage) {
        MacClipboard.copy(message.trimmedText)
    }

    private func friendly(_ failure: AIFailure) -> String {
        switch failure {
        case .missingKey:
            return "No API key set. Add one in Settings → AI, or switch to On-device."
        case .unavailable(let reason):
            return reason.message
        default:
            return failure.message
        }
    }
}

// MARK: - Mac message view
//
// Moved to its own file: `DoomCoder/MacMessageView.swift`.

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

// MARK: - Rainbow idle glow (legacy — moved to RainbowIdleGlow.swift)
//
// The shared `RainbowIdleGlow` struct now lives in `RainbowIdleGlow.swift`
// (top-level of the DoomCoder target) so the iOS Prompts view can reuse
// it without duplicating the implementation. The local declaration here
// was removed; call sites still use `RainbowIdleGlow(cornerRadius: …)`
// unchanged.





// MARK: - Notes (toolbar-driven editor + reminder/checklist inspector)

/// macOS 26 notes workspace: a list (search + new), a comfortable body editor
/// with inline checklist, and an inspector for reminder, pin, and metadata.
/// Selection is by `UUID` so store edits never desync the selection. Reminders
/// schedule a local notification and persist on this Mac only.
struct MacNotesPane: View {
    @State private var store = MacNotesStore.shared
    @State private var search = ""
    @State private var selectedID: UUID?

    private var filtered: [Note] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.sorted }
        return store.sorted.filter {
            $0.title.lowercased().contains(q)
                || $0.body.lowercased().contains(q)
                || $0.checklist.contains { $0.text.lowercased().contains(q) }
        }
    }

    private var selectedNote: Note? { selectedID.flatMap { store.note(id: $0) } }

    var body: some View {
        NavigationSplitView {
            notesSidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            noteDetail
        }
        .navigationTitle("Notes")
        .toolbar {
            ToolbarItem {
                Button { create() } label: { Label("New Note", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New note (⌘N)")
            }
        }
        .onDisappear { store.pruneEmpty() }
    }

    // MARK: History sidebar (saved notes)

    private var notesSidebar: some View {
        list
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
        MacConversationStore.shared.pendingSeed = body
        WindowOpener.open(.prompts)
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

/// The full note editor: title, body, tasks, and reminder are all primary,
/// first-class sections. Content (title/body/checklist) autosaves via
/// `updateContent`; the reminder is set through the store's async scheduler so a
/// stale content snapshot can never clobber it.
// MARK: - MacNoteEditor
//
// Moved to its own file: `DoomCoder/MacNoteEditor.swift`.
