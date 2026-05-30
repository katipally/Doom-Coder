// ReferenceView.swift — DoomCoder Companion (Tools)
// Searchable, copyable CLI cheat sheets for the AI coding tools DoomCoder
// supports. Curated and bundled — fully offline.

import SwiftUI
import UIKit

struct ReferenceView: View {
    @State private var sheets = BundledContent.cheatSheets()
    @State private var search = ""

    private var filtered: [CheatSheet] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sheets }
        return sheets.compactMap { sheet in
            if sheet.tool.lowercased().contains(query) { return sheet }
            let sections = sheet.sections.compactMap { section -> CheatSheetSection? in
                let entries = section.entries.filter {
                    $0.command.lowercased().contains(query) || $0.detail.lowercased().contains(query)
                }
                guard !entries.isEmpty else { return nil }
                return CheatSheetSection(title: section.title, entries: entries)
            }
            guard !sections.isEmpty else { return nil }
            var copy = sheet
            copy.sections = sections
            return copy
        }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                Text("No commands match “\(search)”.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filtered) { sheet in
                    NavigationLink {
                        CheatSheetDetailView(sheet: sheet)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sheet.tool).font(.headline)
                            Text(sheet.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Reference")
        .searchable(text: $search, prompt: "Search commands")
        .overlay(alignment: .bottom) {
            if search.isEmpty {
                Text("Commands change between releases — run the tool's `--help` for the latest.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(8)
            }
        }
    }
}

// MARK: - Detail

struct CheatSheetDetailView: View {
    let sheet: CheatSheet

    var body: some View {
        List {
            Section {
                Text(sheet.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(sheet.sections) { section in
                Section(section.title) {
                    ForEach(section.entries) { entry in
                        EntryRow(entry: entry)
                    }
                }
            }
        }
        .navigationTitle(sheet.tool)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct EntryRow: View {
    let entry: CheatSheetEntry
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = entry.command
            Haptics.success()
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.command)
                        .font(.callout.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.command). \(entry.detail). Tap to copy.")
    }
}
