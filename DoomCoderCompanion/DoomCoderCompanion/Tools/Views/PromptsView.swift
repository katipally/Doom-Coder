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

    @FocusState private var editorFocused: Bool

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var hasContent: Bool { !trimmedDraft.isEmpty }

    var body: some View {
        Form {
            composerSection
            if !store.prompts.isEmpty {
                draftsSection
            }
        }
        .navigationTitle("Prompts")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
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
        .alert("New draft?", isPresented: $showNewConfirm) {
            Button("Save & start new") { saveDraft(); clearEditor() }
            Button("Discard", role: .destructive) { clearEditor() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current draft has unsaved changes.")
        }
    }

    // MARK: - Composer

    @ViewBuilder
    private var composerSection: some View {
        Section {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Describe what you want your AI coding agent to do…")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $draft)
                    .frame(minHeight: 200)
                    .focused($editorFocused)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Prompt draft")
            }
            .font(.body)

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
        } header: {
            Text("Compose")
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
