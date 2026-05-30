// ReferenceView.swift — DoomCoder Companion (Tools)
// Full, curated documentation for the agents DoomCoder supports, plus a grounded
// "Ask" AI chat that answers ONLY from the bundled docs and cites its sources.
// Fully offline: retrieval is deterministic (BM25) and the answer falls back to
// the built-in engine when no Apple Intelligence / API key is available.

import SwiftUI
import UIKit
import DoomCoderCore

struct ReferenceView: View {
    @State private var docs = DocsService.shared
    @State private var search = ""

    private var filtered: [AgentDoc] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return docs.agents }
        return docs.agents.filter { agent in
            if agent.title.lowercased().contains(q) || agent.tagline.lowercased().contains(q) { return true }
            return agent.sections.contains {
                $0.heading.lowercased().contains(q) || $0.body.lowercased().contains(q)
            }
        }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ForEach(filtered) { agent in
                    NavigationLink {
                        AgentDocView(agent: agent)
                    } label: {
                        AgentDocRow(agent: agent)
                    }
                }
            }
            Section {
                Text("Commands change between releases — run the tool's `--help` or check its official docs for the latest.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Reference")
        .searchable(text: $search, prompt: "Search docs")
    }
}

private struct AgentDocRow: View {
    let agent: AgentDoc

    var body: some View {
        HStack(spacing: 12) {
            if let tracked = TrackedAgent(rawValue: agent.id) {
                AgentIcon(agent: tracked, size: 34)
            } else {
                Image(systemName: "book.closed")
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.title).font(.headline)
                Text(agent.tagline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.title). \(agent.tagline)")
    }
}

// MARK: - Per-agent docs reader

struct AgentDocView: View {
    let agent: AgentDoc
    @State private var showChat = false

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Button {
                        showChat = true
                    } label: {
                        Label("Ask about \(agent.title)", systemImage: "sparkles")
                    }
                    .accessibilityHint("Opens an AI assistant grounded in these docs")
                }

                ForEach(agent.sections) { section in
                    Section(section.heading) {
                        DocBodyView(text: section.body)
                    }
                    .id(section.id)
                }

                if let source = agent.source, let url = URL(string: source) {
                    Section {
                        Link(destination: url) {
                            Label("Official documentation", systemImage: "safari")
                        }
                        .font(.callout)
                    }
                }
            }
            .navigationTitle(agent.title)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showChat) {
                AgentChatView(agent: agent) { sectionID in
                    showChat = false
                    withAnimation { proxy.scrollTo(sectionID, anchor: .top) }
                }
            }
        }
    }
}

/// Renders a doc body: bullet lines and inline `code` via lightweight markdown.
private struct DocBodyView: View {
    let text: String

    private var lines: [String] {
        text.components(separatedBy: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Color.clear.frame(height: 2)
                } else {
                    Text(inlineMarkdown(line))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func inlineMarkdown(_ line: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: line, options: opts) {
            return attributed
        }
        return AttributedString(line)
    }
}

// MARK: - Grounded AI chat over the agent's docs

struct AgentChatView: View {
    let agent: AgentDoc
    /// Called when the user taps a citation, with the section id to scroll to.
    var onCitationTap: (String) -> Void

    @State private var coordinator = AIEngineCoordinator.shared
    @State private var question = ""
    @State private var messages: [ChatMessage] = []
    @State private var isThinking = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    struct ChatMessage: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        let text: String
        var citations: [Citation] = []
        var tier: String? = nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if messages.isEmpty {
                    introBanner
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { msg in
                                bubble(msg).id(msg.id)
                            }
                            if isThinking {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Searching the docs…").foregroundStyle(.secondary)
                                }
                                .font(.callout)
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                inputBar
            }
            .navigationTitle("Ask \(agent.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var introBanner: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(.tint)
            Text("Ask anything about \(agent.title)")
                .font(.headline)
            Text("Answers come only from the bundled docs, with citations you can tap. Works offline.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            suggestionChips
        }
        .padding()
    }

    private var suggestionChips: some View {
        let suggestions = ["What does it do?", "How do I install it?", "Common commands"]
        return HStack {
            ForEach(suggestions, id: \.self) { s in
                Button(s) { ask(s) }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
            }
        }
    }

    private func bubble(_ msg: ChatMessage) -> some View {
        VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 6) {
            Text(msg.text)
                .font(.callout)
                .textSelection(.enabled)
                .padding(10)
                .background(msg.role == .user ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)

            if !msg.citations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sources").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(msg.citations) { c in
                        Button {
                            if let sectionID = sectionID(for: c.chunkID) { onCitationTap(sectionID) }
                        } label: {
                            Label(c.title, systemImage: "text.quote")
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about \(agent.title)…", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { ask(question) }
            Button {
                ask(question)
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isThinking)
            .accessibilityLabel("Send")
        }
        .padding(10)
        .background(.bar)
    }

    /// Maps a citation chunk id ("agentID#idx") back to the section id ("idx").
    private func sectionID(for chunkID: String) -> String? {
        guard let hash = chunkID.firstIndex(of: "#") else { return nil }
        return String(chunkID[chunkID.index(after: hash)...])
    }

    private func ask(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isThinking else { return }
        question = ""
        fieldFocused = false
        messages.append(ChatMessage(role: .user, text: q))
        isThinking = true

        Task {
            let chunks = DocsService.shared.retrieve(query: q, agentID: agent.id, limit: 4)
            let result = await coordinator.chat(question: q, context: chunks)
            await MainActor.run {
                isThinking = false
                switch result {
                case .success(let answer, let tier):
                    messages.append(ChatMessage(role: .assistant, text: answer.answer,
                                                citations: answer.citations, tier: tier.shortName))
                case .failure(let failure, _):
                    messages.append(ChatMessage(role: .assistant,
                                                text: friendlyError(failure)))
                }
                Haptics.success()
            }
        }
    }

    private func friendlyError(_ failure: AIFailure) -> String {
        switch failure {
        case .missingKey:
            return "Add your API key in Settings to use your own model, or switch to the built-in engine — both can answer from these docs."
        case .network:
            return "I couldn't reach the provider. Check your connection, or switch to the built-in engine in Settings to keep working offline."
        case .rateLimited:
            return "The provider is rate-limiting requests right now. Try again in a moment, or use the built-in engine."
        default:
            return "I couldn't find an answer in the bundled docs for that. Try rephrasing, or read the sections above."
        }
    }
}
