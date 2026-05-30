// ComposerView.swift — DoomCoder Companion (Tools)
// The Prompt Composer: start from a blank description of what you want, let the
// shared 3-tier AIEngine turn it into a reusable template with fill-in fields,
// then fill, tweak inline, enhance, copy, and/or save it to your library.
// Works on every device — with no key the built-in engine composes offline.

import SwiftUI
import DoomCoderCore

struct ComposerView: View {
    /// Called with the saved template when the user taps "Save to library".
    var onSaved: ((Prompt) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var ai = AIEngineCoordinator.shared
    @State private var store = PromptStore.shared

    @State private var intent = ""
    @State private var phase: Phase = .describe
    @State private var template: ComposedTemplate?
    @State private var values: [String: String] = [:]
    @State private var editedBody: String = ""          // live, inline-editable final prompt
    @State private var usingEditedBody = false
    @State private var notice: String?
    @State private var isWorking = false

    private enum Phase { case describe, ready }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .describe: describeSection
                case .ready: readySections
                }
            }
            .navigationTitle("Compose a Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if phase == .ready {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    // MARK: - Describe phase

    @ViewBuilder
    private var describeSection: some View {
        Section {
            TextEditor(text: $intent)
                .frame(minHeight: 130)
                .font(.body)
        } header: {
            Text("Describe what you want")
        } footer: {
            Text("Plain English is fine. e.g. “help me write unit tests for a Swift networking layer that uses async/await.”")
        }

        Section {
            LabeledContent("AI engine") {
                Text(ai.selection.displayName).foregroundStyle(.secondary)
            }
        } footer: {
            Text(ai.selection.detail)
        }

        Section {
            Button {
                Task { await build() }
            } label: {
                HStack {
                    if isWorking { ProgressView().controlSize(.small) }
                    Text(isWorking ? "Composing…" : "Build template")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }

        if let notice {
            Section {
                Label(notice, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Ready phase

    @ViewBuilder
    private var readySections: some View {
        if let template {
            let fields = template.fields

            Section {
                LabeledContent("Title") { Text(template.title).foregroundStyle(.secondary) }
                LabeledContent("Category") {
                    Label(template.category.displayName, systemImage: template.category.symbol)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if let notice { Text(notice) }
            }

            if !fields.isEmpty {
                Section("Fill in") {
                    ForEach(fields, id: \.key) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.label).font(.caption).foregroundStyle(.secondary)
                            if field.multiline {
                                TextEditor(text: binding(for: field.key))
                                    .frame(minHeight: 70).font(.callout)
                            } else {
                                TextField(field.hint.isEmpty ? field.label : field.hint,
                                          text: binding(for: field.key))
                            }
                        }
                    }
                }
            }

            Section {
                TextEditor(text: finalBinding(for: template))
                    .font(.callout)
                    .frame(minHeight: 200)
            } header: {
                Text("Final prompt")
            } footer: {
                Text("Edit anything directly here. Filling fields above updates this until you start editing it by hand.")
            }

            Section {
                CopyButton(text: renderedFinal(for: template), title: "Copy prompt", prominent: true)
                Button {
                    Task { await enhanceFinal() }
                } label: {
                    HStack {
                        if isWorking { ProgressView().controlSize(.small) }
                        Label(isWorking ? "Enhancing…" : "Enhance", systemImage: "sparkles")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
                Button {
                    reset()
                } label: {
                    Label("Start over", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    // MARK: - Rendering

    private func renderedFinal(for template: ComposedTemplate) -> String {
        if usingEditedBody { return editedBody }
        return template.toPrompt().render(values: values)
    }

    private func finalBinding(for template: ComposedTemplate) -> Binding<String> {
        Binding(
            get: { usingEditedBody ? editedBody : template.toPrompt().render(values: values) },
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

    // MARK: - Actions

    private func build() async {
        let raw = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        isWorking = true; notice = nil
        defer { isWorking = false }

        let outcome = await ai.compose(intent: raw)
        switch outcome {
        case .success(let composed, let tier):
            template = composed
            values = [:]
            usingEditedBody = false
            editedBody = ""
            notice = "Drafted with \(tier.displayName). Tweak the fields or the prompt itself."
            phase = .ready
            Haptics.success()
        case .failure(let failure, _):
            notice = failure.message
            Haptics.warning()
        }
    }

    private func enhanceFinal() async {
        guard let template else { return }
        isWorking = true
        defer { isWorking = false }
        let current = renderedFinal(for: template)
        let outcome = await ai.enhance(current)
        switch outcome {
        case .success(let improved, let tier):
            usingEditedBody = true
            editedBody = improved
            notice = "Enhanced with \(tier.displayName)."
            Haptics.success()
        case .failure(let failure, _):
            notice = failure.message
            Haptics.warning()
        }
    }

    private func save() {
        guard let template else { return }
        // Persist the reusable template (keeps the fill-in fields). If the user
        // hand-edited the final text, save that as a no-field prompt instead so
        // their exact wording is preserved.
        let prompt: Prompt
        if usingEditedBody {
            prompt = Prompt(title: template.title, category: template.category, body: editedBody)
        } else {
            prompt = template.toPrompt()
        }
        store.add(prompt)
        Haptics.success()
        onSaved?(prompt)
        dismiss()
    }

    private func reset() {
        phase = .describe
        template = nil
        values = [:]
        usingEditedBody = false
        editedBody = ""
        notice = nil
        Haptics.tap()
    }
}
