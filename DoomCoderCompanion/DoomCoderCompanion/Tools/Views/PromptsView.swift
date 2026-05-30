// PromptsView.swift — DoomCoder Companion (Tools)
// The Prompt Composer: a single-screen, freeform workspace. Write a rough draft,
// optionally Enhance it with AI (rewritten in place), then Copy, Save, or start a
// New draft. Saved drafts live below and load back into the editor on tap.
// Works fully standalone — writing and copying need no AI at all.

import SwiftUI
import DoomCoderCore

struct PromptsView: View {
    @State private var store = PromptStore.shared
    @State private var ai = AIEngineCoordinator.shared

    @State private var draft = ""
    @State private var currentDraftID: UUID?
    @State private var preEnhance: String?

    @State private var isEnhancing = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showNewConfirm = false

    @State private var showLibrary = false
    @State private var librarySearch = ""

    @State private var editorFocused = false

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var hasContent: Bool { !trimmedDraft.isEmpty }

    var body: some View {
        content
            // Large title, consistent with Notes and Dashboard.
            .navigationTitle("Prompts")
            .toolbar {
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
                        startNewDraft()
                    } label: {
                        Label("New draft", systemImage: "square.and.pencil")
                    }
                    .disabled(!hasContent && currentDraftID == nil)
                    .accessibilityLabel("New draft")
                }
            }
            .sheet(isPresented: $showLibrary) {
                librarySheet
            }
            .alert("New draft?", isPresented: $showNewConfirm) {
                Button("Save & start new") { saveDraft(); clearEditor() }
                Button("Discard", role: .destructive) { clearEditor() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your current draft has unsaved changes.")
            }
    }

    private var content: some View {
        Form {
            composerSection
            if !store.prompts.isEmpty {
                draftsSection
            }
        }
        .refreshable { store.reload() }
    }

    // MARK: - Composer

    @ViewBuilder
    private var composerSection: some View {
        Section {
            // Fixed-height, internally-scrolling editor: a long draft (or one
            // loaded from a saved draft) no longer expands the editor to full
            // screen. The chevron appears only when content overflows.
            PromptEditorBox(
                text: $draft,
                isFocused: $editorFocused,
                placeholder: "Describe what you want your AI coding agent to do…"
            )
            .frame(height: 240)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))

            actionBar

            if isEnhancing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Enhancing with \(ai.selection.displayName)…")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .accessibilityElement(children: .combine)
            } else if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .transition(.opacity)
            }
        } footer: {
            composerFooter
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: 10) {
            Button {
                Task { await enhance() }
            } label: {
                Label(preEnhance == nil ? "Enhance with AI" : "Enhance again",
                      systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!hasContent || isEnhancing)

            HStack(spacing: 10) {
                Button {
                    copyDraft()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }
                .disabled(!hasContent)

                Button {
                    saveDraft()
                } label: {
                    Label(currentDraftID == nil ? "Save" : "Update",
                          systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity)
                }
                .disabled(!hasContent)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            if preEnhance != nil {
                Button(role: .cancel) {
                    revertEnhance()
                } label: {
                    Label("Undo enhance", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var composerFooter: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Text("Enhance rewrites your draft using \(ai.selection.displayName). Writing and copying never require AI. Set up AI in Settings → AI.")
        }
    }

    // MARK: - Saved drafts

    @ViewBuilder
    private var draftsSection: some View {
        Section("Saved drafts") {
            ForEach(store.draftsByRecent) { prompt in
                Button {
                    loadDraft(prompt)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.title(for: prompt.body))
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(prompt.body)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(prompt.updatedAt, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .listRowBackground(prompt.id == currentDraftID ? Color.accentColor.opacity(0.12) : nil)
                .accessibilityHint("Loads this draft into the editor")
            }
            .onDelete { offsets in
                let visible = store.draftsByRecent
                let removingCurrent = offsets.contains { visible[$0].id == currentDraftID }
                store.delete(at: offsets, in: visible)
                if removingCurrent { currentDraftID = nil }
            }
        }
    }

    // MARK: - Library

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

    /// The curated prompt library, presented as a sheet (like the note editor).
    /// Tapping a prompt loads it into the composer and dismisses the sheet.
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

    @ViewBuilder
    private func libraryRow(_ prompt: Prompt) -> some View {
        Button {
            openInComposer(prompt)
        } label: {
            HStack(alignment: .top, spacing: 12) {
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

                Button {
                    copyLibraryPrompt(prompt)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .accessibilityLabel("Copy “\(prompt.title)”")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this prompt in the composer to tailor it")
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                copyLibraryPrompt(prompt)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .tint(.accentColor)
        }
        .contextMenu {
            Button {
                copyLibraryPrompt(prompt)
            } label: {
                Label("Copy prompt", systemImage: "doc.on.doc")
            }
            Button {
                openInComposer(prompt)
            } label: {
                Label("Open in composer", systemImage: "square.and.pencil")
            }
        }
    }

    private func copyLibraryPrompt(_ prompt: Prompt) {
        UIPasteboard.general.string = prompt.render(values: [:])
        flashStatus("Copied “\(prompt.title)”")
        Haptics.success()
    }

    /// Loads a library prompt's raw template into the composer as a new, unsaved
    /// draft so the user can fill in the `{{placeholders}}` and enhance/copy it.
    private func openInComposer(_ prompt: Prompt) {
        draft = prompt.body
        currentDraftID = nil
        preEnhance = nil
        errorMessage = nil
        statusMessage = nil
        librarySearch = ""
        showLibrary = false
        Haptics.tap()
    }

    // MARK: - Actions

    private func enhance() async {
        guard hasContent, !isEnhancing else { return }
        editorFocused = false
        errorMessage = nil
        statusMessage = nil
        isEnhancing = true
        let snapshot = draft
        let capturedID = currentDraftID
        let result = await ai.enhance(trimmedDraft)
        isEnhancing = false
        // Ignore the result if the user switched drafts or edited while it ran.
        guard currentDraftID == capturedID, draft == snapshot else { return }
        switch result {
        case .success(let improved, _):
            preEnhance = snapshot
            withAnimation { draft = improved }
            Haptics.success()
        case .failure(let failure, _):
            errorMessage = friendly(failure)
            Haptics.warning()
        }
    }

    private func revertEnhance() {
        guard let original = preEnhance else { return }
        withAnimation { draft = original }
        preEnhance = nil
        Haptics.tap()
    }

    private func copyDraft() {
        UIPasteboard.general.string = trimmedDraft
        flashStatus("Copied to clipboard")
        Haptics.success()
    }

    private func saveDraft() {
        guard hasContent else { return }
        if let id = currentDraftID, var existing = store.prompts.first(where: { $0.id == id }) {
            existing.body = trimmedDraft
            existing.title = Self.title(for: trimmedDraft)
            store.update(existing)
            flashStatus("Draft updated")
        } else {
            let prompt = Prompt(title: Self.title(for: trimmedDraft),
                                category: .general,
                                body: trimmedDraft)
            store.add(prompt)
            currentDraftID = prompt.id
            flashStatus("Draft saved")
        }
        preEnhance = nil
        Haptics.success()
    }

    private func startNewDraft() {
        if hasContent && !isCurrentSaved() {
            showNewConfirm = true
        } else {
            clearEditor()
        }
    }

    private func clearEditor() {
        withAnimation {
            draft = ""
            currentDraftID = nil
            preEnhance = nil
            errorMessage = nil
            statusMessage = nil
        }
        editorFocused = true
    }

    private func loadDraft(_ prompt: Prompt) {
        if hasContent && !isCurrentSaved() && currentDraftID != prompt.id {
            saveDraft()
        }
        draft = prompt.body
        currentDraftID = prompt.id
        preEnhance = nil
        errorMessage = nil
        statusMessage = nil
        editorFocused = false
        Haptics.tap()
    }

    /// True when the editor content matches the currently-loaded saved draft.
    private func isCurrentSaved() -> Bool {
        guard let id = currentDraftID,
              let existing = store.prompts.first(where: { $0.id == id }) else { return false }
        return existing.body == trimmedDraft
    }

    private func flashStatus(_ message: String) {
        withAnimation { statusMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if statusMessage == message { statusMessage = nil } }
        }
    }

    private func friendly(_ failure: AIFailure) -> String {
        switch failure {
        case .missingKey:
            return "No API key set. Add one in Settings → AI, or switch to On-device."
        case .unavailable(let reason):
            return "\(reason.message) Choose “My API key” in Settings → AI to use a provider instead."
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

// MARK: - Fixed-height prompt editor

/// A fixed-height text editor that scrolls its content internally and surfaces a
/// "scroll to bottom" affordance only when the text overflows the visible box.
/// Backed by `UITextView` so we get reliable programmatic scrolling and a
/// placeholder — SwiftUI's `TextEditor` exposes neither.
private struct PromptEditorBox: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String

    @State private var canScrollDown = false
    @State private var scrollToken = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollableTextView(
                text: $text,
                isFocused: $isFocused,
                canScrollDown: $canScrollDown,
                scrollToBottomToken: scrollToken
            )
            .accessibilityLabel("Prompt draft")

            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.leading, 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Only shown when there's content below the current scroll position
            // (i.e. the user has scrolled up / isn't already at the bottom).
            if canScrollDown {
                Button {
                    scrollToken &+= 1
                    Haptics.tap()
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.separator))
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Scroll to bottom of draft")
                .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: canScrollDown)
    }
}

/// `UITextView`-backed editor with two-way text + focus binding, overflow
/// reporting, and a token-driven scroll-to-bottom.
private struct ScrollableTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var canScrollDown: Bool
    var scrollToBottomToken: Int

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.adjustsFontForContentSizeCategory = true
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        tv.textContainer.lineFragmentPadding = 4
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.text = text
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text {
            tv.text = text
            context.coordinator.recomputeCanScrollDown(tv)
        }

        if isFocused, !tv.isFirstResponder {
            DispatchQueue.main.async { tv.becomeFirstResponder() }
        } else if !isFocused, tv.isFirstResponder {
            DispatchQueue.main.async { tv.resignFirstResponder() }
        }

        if context.coordinator.lastScrollToken != scrollToBottomToken {
            context.coordinator.lastScrollToken = scrollToBottomToken
            DispatchQueue.main.async {
                let end = NSRange(location: (tv.text as NSString).length, length: 0)
                tv.scrollRangeToVisible(end)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ScrollableTextView
        var lastScrollToken: Int

        init(_ parent: ScrollableTextView) {
            self.parent = parent
            self.lastScrollToken = parent.scrollToBottomToken
        }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            recomputeCanScrollDown(tv)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let tv = scrollView as? UITextView else { return }
            recomputeCanScrollDown(tv)
        }

        func textViewDidBeginEditing(_ tv: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        /// True only when there is content BELOW the current scroll position —
        /// i.e. the editor isn't already scrolled to the bottom. Deferred to
        /// avoid mutating SwiftUI state mid-update.
        func recomputeCanScrollDown(_ tv: UITextView) {
            let distanceToBottom = tv.contentSize.height - (tv.contentOffset.y + tv.bounds.height)
            let canScroll = distanceToBottom > 24
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.parent.canScrollDown != canScroll { self.parent.canScrollDown = canScroll }
            }
        }
    }
}
