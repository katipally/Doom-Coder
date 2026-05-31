// PromptsView.swift — DoomCoder Companion (Tools)
// The Prompt workspace, redesigned as a refine transcript (iMessage-style):
// the user types a rough request, the AI streams back a refined prompt rendered
// plain on the background with a Copy button, and follow-up messages refine the
// result. Every conversation auto-saves to local History and reopens to continue.
// Fully standalone — typing and copying need no AI. Local-only; never synced.

import SwiftUI
import DoomCoderCore

struct PromptsView: View {
    @State private var store = ConversationStore.shared
    @State private var ai = AIEngineCoordinator.shared
    @State private var router = AppRouter.shared

    /// The transcript currently on screen (the live source of truth while open).
    @State private var active = Conversation()

    @State private var input = ""
    @State private var isGenerating = false
    @State private var generationTask: Task<Void, Never>?
    /// IDs of the in-flight exchange, so Stop can discard it and restore the input.
    @State private var inflightUserID: UUID?
    @State private var inflightAssistantID: UUID?
    /// Identifies the current generation so a stale task that unwinds late can't
    /// clobber `isGenerating` or message state for a newer one.
    @State private var generationID: UUID?

    @State private var showHistory = false
    @State private var showLibrary = false
    @State private var librarySearch = ""
    @State private var renameTarget: Conversation?
    @State private var renameText = ""
    @State private var pendingEditID: UUID?

    @FocusState private var inputFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmedInput.isEmpty && !isGenerating }

    var body: some View {
        transcript
            .navigationTitle("Prompts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) { inputBar }
            .sheet(isPresented: $showHistory) { historySheet }
            .sheet(isPresented: $showLibrary) { librarySheet }
            .alert("Rename conversation", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Title", text: $renameText)
                Button("Save") {
                    if let target = renameTarget {
                        store.rename(target.id, to: renameText)
                        if active.id == target.id { active.customTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines) }
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
            .onChange(of: router.pendingPromptSeed) { _, _ in consumePendingSeed() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showHistory = true
                Haptics.tap()
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .accessibilityLabel("Conversation history")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showLibrary = true
                Haptics.tap()
            } label: {
                Label("Library", systemImage: "books.vertical")
            }
            .accessibilityLabel("Prompt library")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                newChat()
                Haptics.tap()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .disabled(active.messages.isEmpty && !isGenerating)
            .accessibilityLabel("New chat")
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if active.messages.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, minHeight: 420)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(active.messages) { message in
                            MessageView(
                                message: message,
                                onCopy: { copy(message) },
                                onRetry: { retry(message.id) },
                                onEdit: { requestEdit(message.id) }
                            )
                            .id(message.id)
                        }
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: active.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: streamingSignature) { _, _ in scrollToBottom(proxy) }
        }
    }

    /// Changes whenever the in-flight assistant text grows, to drive auto-scroll.
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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Refine a prompt")
                    .font(.title2.weight(.semibold))
                Text("Describe what you want your AI coding agent to do. I'll rewrite it into a clear, structured prompt you can copy.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            if !quickStarts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Try one")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(quickStarts) { prompt in
                        Button {
                            input = prompt.body
                            inputFocused = true
                            Haptics.tap()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: prompt.category.symbol)
                                    .font(.footnote)
                                    .foregroundStyle(.tint)
                                Text(prompt.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Fills the message box with this starter prompt")
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        .padding(.vertical, 32)
    }

    private var quickStarts: [Prompt] {
        PromptLibrary.grouped().prefix(4).compactMap { $0.prompts.first }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 8) {
            if showSetupBanner {
                setupBanner
            }
            // iMessage-style capsule: button lives inside the glass container.
            HStack(alignment: .bottom, spacing: 0) {
                TextField("Describe your prompt…", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .padding(.leading, 14)
                    .padding(.vertical, 10)
                    .padding(.trailing, 4)
                    .accessibilityLabel("Message")

                Group {
                    if isGenerating {
                        Button {
                            stop()
                            Haptics.tap()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(.red.gradient, in: .circle)
                        }
                        .accessibilityLabel("Stop generating")
                    } else {
                        Button { send() } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background {
                                    Circle().fill(canSend
                                        ? AnyShapeStyle(Color.accentColor.gradient)
                                        : AnyShapeStyle(Color(uiColor: .systemFill)))
                                }
                        }
                        .disabled(!canSend)
                        .accessibilityLabel("Refine prompt")
                    }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .padding(.bottom, 6)
            }
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var showSetupBanner: Bool {
        ai.selection == .remoteKey && !ai.hasKeyForCurrentProvider
    }

    private var setupBanner: some View {
        Button {
            router.selectedTab = .settings
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

    // MARK: - History sheet

    private var historySheet: some View {
        NavigationStack {
            Group {
                if store.byRecent.isEmpty {
                    ContentUnavailableView(
                        "No history yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Your refined prompts will appear here automatically.")
                    )
                } else {
                    List {
                        ForEach(store.byRecent) { conversation in
                            Button { open(conversation) } label: { historyRow(conversation) }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        deleteConversation(conversation.id)
                                        Haptics.warning()
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        renameText = conversation.displayTitle
                                        renameTarget = conversation
                                    } label: { Label("Rename", systemImage: "pencil") }
                                    .tint(.orange)
                                }
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
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showHistory = false }
                }
            }
        }
    }

    private func historyRow(_ conversation: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(conversation.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if conversation.id == active.id {
                    Text("Current")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - Library sheet

    private var filteredLibrary: [(category: PromptCategory, prompts: [Prompt])] {
        let query = librarySearch.trimmingCharacters(in: .whitespaces).lowercased()
        return PromptLibrary.grouped().compactMap { group in
            guard !query.isEmpty else { return group }
            let matches = group.prompts.filter { prompt in
                prompt.title.lowercased().contains(query)
                    || prompt.body.lowercased().contains(query)
                    || prompt.tags.contains { $0.lowercased().contains(query) }
            }
            return matches.isEmpty ? nil : (group.category, matches)
        }
    }

    private var librarySheet: some View {
        NavigationStack {
            List {
                if filteredLibrary.isEmpty {
                    ContentUnavailableView.search(text: librarySearch)
                } else {
                    ForEach(filteredLibrary, id: \.category) { group in
                        Section {
                            ForEach(group.prompts) { prompt in
                                libraryRow(prompt)
                            }
                        } header: {
                            Label(group.category.displayName, systemImage: group.category.symbol)
                        }
                    }
                }
            }
            .navigationTitle("Prompt Library")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $librarySearch, prompt: "Search prompts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showLibrary = false }
                }
            }
        }
    }

    private func libraryRow(_ prompt: Prompt) -> some View {
        Button {
            input = prompt.body
            librarySearch = ""
            showLibrary = false
            inputFocused = true
            Haptics.tap()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(prompt.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(prompt.render(values: [:]))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Inserts this prompt into the message box")
    }

    // MARK: - Generation

    private func send() {
        let text = trimmedInput
        guard !text.isEmpty, !isGenerating else { return }
        inputFocused = false
        let userMsg = ChatMessage(role: .user, text: text)
        let assistantMsg = ChatMessage(role: .assistant, tier: ai.activeTier, status: .streaming)
        active.messages.append(userMsg)
        active.messages.append(assistantMsg)
        inflightUserID = userMsg.id
        inflightAssistantID = assistantMsg.id
        input = ""
        isGenerating = true
        persistActive()
        let convID = active.id
        let assistantID = assistantMsg.id
        let token = UUID()
        generationID = token
        generationTask = Task { await runGeneration(conversationID: convID, assistantID: assistantID, token: token) }
        Haptics.tap()
    }

    @MainActor
    private func runGeneration(conversationID: UUID, assistantID: UUID, token: UUID) async {
        defer { if generationID == token { isGenerating = false; generationID = nil } }
        let transcript = active.engineTranscript()
        func isCurrent() -> Bool { generationID == token && active.id == conversationID }
        do {
            for try await chunk in ai.stream(transcript: transcript) {
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
            Haptics.success()
        } catch let failure as AIFailure {
            if case .cancelled = failure { return }
            guard isCurrent() else { return }
            updateMessage(assistantID) { m in
                m.status = .failed
                m.errorText = friendly(failure)
            }
            clearInflight()
            persistActive()
            Haptics.warning()
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
            Haptics.warning()
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
        let assistantMsg = ChatMessage(role: .assistant, tier: ai.activeTier, status: .streaming)
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
        Haptics.tap()
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
        Haptics.tap()
    }

    // MARK: - Conversation lifecycle

    private func newChat() {
        cancelInFlight()
        saveActiveIfNeeded()
        active = Conversation()
        input = ""
        inputFocused = true
    }

    private func open(_ conversation: Conversation) {
        cancelInFlight()
        saveActiveIfNeeded()
        active = conversation
        input = ""
        showHistory = false
        inputFocused = false
    }

    private func deleteConversation(_ id: UUID) {
        store.delete(id)
        if active.id == id {
            cancelInFlight()
            active = Conversation()
            input = ""
        }
    }

    private func consumePendingSeed() {
        guard let seed = router.pendingPromptSeed else { return }
        router.pendingPromptSeed = nil
        cancelInFlight()
        saveActiveIfNeeded()
        active = Conversation()
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
        UIPasteboard.general.string = message.trimmedText
        Haptics.success()
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

// MARK: - Message view

/// Renders one transcript message: user requests as trailing glass bubbles, the
/// AI's refined prompt as plain leading text under a "Refined prompt" header with
/// a Copy action, and failures inline with Retry.
private struct MessageView: View {
    let message: ChatMessage
    let onCopy: () -> Void
    let onRetry: () -> Void
    let onEdit: () -> Void

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantContent
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)
            Text(message.text)
                .font(.body)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint(.accentColor.opacity(0.18)), in: .rect(cornerRadius: 18))
                .contextMenu {
                    Button { onEdit() } label: { Label("Edit & resend", systemImage: "pencil") }
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(message.text)")
    }

    @ViewBuilder
    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch message.status {
            case .streaming:
                if message.trimmedText.isEmpty {
                    refiningHeader
                } else {
                    header("Refined prompt")
                    Text(message.text)
                        .font(.body)
                        .textSelection(.enabled)
                }
            case .complete:
                header("Refined prompt")
                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
                Button {
                    onCopy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.glass)
                .clipShape(.capsule)
                .padding(.top, 2)
                .accessibilityHint("Copies the refined prompt")
            case .failed, .cancelled:
                failureView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var refiningHeader: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Refining…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Refining your prompt")
    }

    private func header(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.tint)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let tier = message.tier {
                Text("· \(tier.shortName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var failureView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message.errorText ?? "Something went wrong.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button {
                onRetry()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.glass)
            .clipShape(.capsule)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}
