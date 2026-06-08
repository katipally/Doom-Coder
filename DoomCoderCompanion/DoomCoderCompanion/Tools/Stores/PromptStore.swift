// PromptStore.swift — Doom Coder Companion (Tools)
// On-device store for the user's saved prompt drafts. Pure composer model: the
// user writes a draft, optionally enhances it with AI, and saves it here. No
// curated examples, no templates — just the user's own drafts. Local-only.

import Foundation
import Observation
import DoomCoderCore

@MainActor
@Observable
final class PromptStore {
    static let shared = PromptStore()

    private let fileName = "prompts.json"

    private(set) var prompts: [Prompt] = []

    private init() {
        if let saved = JSONFileStore.load([Prompt].self, from: fileName) {
            // Migration: drop any previously-seeded curated example prompts so the
            // tab is purely the user's own drafts.
            let drafts = saved.filter { !$0.isCurated }
            prompts = drafts
            if drafts.count != saved.count { persist() }
        }
    }

    /// Saved drafts, most-recently-updated first.
    var draftsByRecent: [Prompt] {
        prompts.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Re-reads drafts from disk (drives pull-to-refresh).
    func reload() {
        if let saved = JSONFileStore.load([Prompt].self, from: fileName) {
            prompts = saved.filter { !$0.isCurated }
        }
    }

    // MARK: - Mutations

    func add(_ prompt: Prompt) {
        prompts.append(prompt)
        persist()
    }

    func update(_ prompt: Prompt) {
        guard let idx = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        var updated = prompt
        updated.updatedAt = Date()
        prompts[idx] = updated
        persist()
    }

    func delete(_ prompt: Prompt) {
        prompts.removeAll { $0.id == prompt.id }
        persist()
    }

    func delete(at offsets: IndexSet, in visible: [Prompt]) {
        let ids = offsets.map { visible[$0].id }
        prompts.removeAll { ids.contains($0.id) }
        persist()
    }

    /// Removes every draft (used by Settings → Manage data).
    func deleteAll() {
        prompts.removeAll()
        persist()
    }

    private func persist() {
        JSONFileStore.save(prompts, to: fileName)
    }
}
