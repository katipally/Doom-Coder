// EnhanceView.swift — DoomCoder Companion (Tools)
// Turns a rough idea into a well-structured prompt. Two modes:
//   • Offline checklist (default) — deterministic local scaffold, no network/key.
//   • Smart (BYO key)            — uses the user's OWN OpenAI/Anthropic key,
//                                  device → provider over HTTPS, falling back to
//                                  the offline scaffold on any failure.
// Returns the improved text to the caller via `onUse`.

import SwiftUI

struct EnhanceView: View {
    /// Seed text (e.g. the prompt body being edited, or empty for a new idea).
    let initialText: String
    /// Called with the improved prompt when the user taps "Use this".
    let onUse: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keySettings = AIKeySettings.shared

    @State private var idea: String
    @State private var result: String = ""
    @State private var isWorking = false
    @State private var noticeText: String?
    @State private var useSmart: Bool

    init(initialText: String = "", onUse: @escaping (String) -> Void) {
        self.initialText = initialText
        self.onUse = onUse
        _idea = State(initialValue: initialText)
        _useSmart = State(initialValue: AIKeySettings.shared.hasKeyForCurrentProvider)
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
                    Toggle(isOn: $useSmart) {
                        Label("Smart enhance", systemImage: "sparkles")
                    }
                    .disabled(!keySettings.hasKeyForCurrentProvider)

                    if keySettings.hasKeyForCurrentProvider {
                        Text("Uses your \(keySettings.provider.displayName) key. Your idea is sent only to \(keySettings.provider.displayName).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Add an API key in Settings to enable Smart enhance. Until then, the offline checklist is used — no internet required.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                        Text(result)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
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

        if useSmart, keySettings.hasKeyForCurrentProvider,
           let apiKey = keySettings.key(for: keySettings.provider) {
            do {
                let improved = try await AIEnhanceService.enhance(
                    raw, provider: keySettings.provider, apiKey: apiKey)
                result = improved
                noticeText = "Enhanced with \(keySettings.provider.displayName)."
                Haptics.success()
                return
            } catch {
                // Graceful fallback: never leave the user empty-handed.
                result = OfflineEnhancer.enhance(raw)
                noticeText = "Smart enhance failed (\(error.localizedDescription)) — used the offline checklist instead."
                Haptics.warning()
                return
            }
        }

        result = OfflineEnhancer.enhance(raw)
        noticeText = "Structured with the offline checklist."
        Haptics.success()
    }
}
