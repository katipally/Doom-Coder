// EnhanceView.swift — DoomCoder Companion (Tools)
// Turns a rough idea into a well-structured prompt using the shared 3-tier
// AIEngine (on-device Apple Intelligence → your API key → built-in offline).
// The engine and fallback policy are owned by AIEngineCoordinator, so this view
// just asks it to enhance and surfaces which tier answered. Returns the improved
// text to the caller via `onUse`.

import SwiftUI
import DoomCoderCore

struct EnhanceView: View {
    /// Seed text (e.g. the prompt body being edited, or empty for a new idea).
    let initialText: String
    /// Called with the improved prompt when the user taps "Use this".
    let onUse: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ai = AIEngineCoordinator.shared

    @State private var idea: String
    @State private var result: String = ""
    @State private var isWorking = false
    @State private var noticeText: String?

    init(initialText: String = "", onUse: @escaping (String) -> Void) {
        self.initialText = initialText
        self.onUse = onUse
        _idea = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $idea)
                        .frame(minHeight: 110)
                        .font(.body)
                } header: {
                    Text("Your rough idea")
                } footer: {
                    Text("Describe what you want your agent to do — even a half sentence works.")
                }

                Section {
                    LabeledContent("AI engine") {
                        Text(ai.selection.displayName)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(ai.selection.detail)
                }

                Section {
                    Button {
                        Task { await runEnhance() }
                    } label: {
                        HStack {
                            if isWorking { ProgressView().controlSize(.small) }
                            Text(isWorking ? "Enhancing…" : "Enhance")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if let noticeText {
                    Section {
                        Label(noticeText, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !result.isEmpty {
                    Section("Improved prompt") {
                        TextEditor(text: $result)
                            .font(.callout)
                            .frame(minHeight: 160)
                        CopyButton(text: result)
                        Button {
                            Haptics.tap()
                            onUse(result)
                            dismiss()
                        } label: {
                            Label("Use this prompt", systemImage: "arrow.down.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Enhance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func runEnhance() async {
        let raw = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        isWorking = true
        noticeText = nil
        defer { isWorking = false }

        let outcome = await ai.enhance(raw)
        switch outcome {
        case .success(let improved, let tier):
            result = improved
            noticeText = "Enhanced with \(tier.displayName)."
            Haptics.success()
        case .failure(let failure, _):
            noticeText = failure.message
            Haptics.warning()
        }
    }
}
