// ToolsView.swift — DoomCoder Companion (Tools)
// The default tab: a hub of 100%-on-device developer tools that work with NO Mac.
// Prompts · Reference · Tasks · Notes. This is the standalone functionality that
// makes the app useful on first launch (App Store guideline 4.2.3).

import SwiftUI

struct ToolsView: View {
    @State private var prompts = PromptStore.shared
    @State private var notes = NotesStore.shared

    var body: some View {
        List {
            Section {
                ToolRow(
                    symbol: "text.alignleft",
                    tint: .purple,
                    title: "Prompts",
                    subtitle: "Compose reusable prompt templates for your AI coding agent. Fill in the blanks and copy.",
                    badge: "\(prompts.prompts.count)"
                ) { PromptsView() }

                ToolRow(
                    symbol: "terminal",
                    tint: .blue,
                    title: "Reference",
                    subtitle: "Full docs + AI chat for Claude Code, Codex, Copilot, Cursor & more.",
                    badge: nil
                ) { ReferenceView() }

                ToolRow(
                    symbol: "note.text",
                    tint: .orange,
                    title: "Notes",
                    subtitle: "Notes with checklists and reminders for your coding work.",
                    badge: notes.notes.isEmpty ? nil : "\(notes.notes.count)"
                ) { NotesView() }
            } header: {
                Text("AI Coding Toolkit")
            } footer: {
                Text("Everything here works entirely on your device — no Mac, no account, no internet required. Connect a Mac in the Dashboard tab to also monitor live agents.")
            }
        }
        .navigationTitle("Tools")
    }
}

// MARK: - Tool row

private struct ToolRow<Destination: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let badge: String?
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(tint.opacity(0.18), in: Capsule())
                                .foregroundStyle(tint)
                        }
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
        }
        .accessibilityHint(subtitle)
    }
}
