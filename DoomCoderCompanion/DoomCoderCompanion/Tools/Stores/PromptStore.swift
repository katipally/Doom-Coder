// PromptStore.swift — DoomCoder Companion (Tools)
// On-device store for the Prompt Library: curated starters (seeded once) plus the
// user's own prompts, with full create/edit/delete/favorite. Local-only.

import Foundation
import Observation

@MainActor
@Observable
final class PromptStore {
    static let shared = PromptStore()

    private let fileName = "prompts.json"
    private let seededKey = "tools.prompts.seeded.v1"

    private(set) var prompts: [Prompt] = []

    private init() {
        if let saved = JSONFileStore.load([Prompt].self, from: fileName) {
            prompts = saved
        } else if !UserDefaults.standard.bool(forKey: seededKey) {
            // First launch: seed curated starters once. If the user later deletes
            // them, they stay deleted (the seeded flag prevents re-seeding).
            prompts = BundledContent.starterPrompts()
            UserDefaults.standard.set(true, forKey: seededKey)
            persist()
        }
    }

    // MARK: - Queries

    func filtered(search: String, category: PromptCategory?, favoritesOnly: Bool) -> [Prompt] {
        var result = prompts
        if favoritesOnly { result = result.filter(\.isFavorite) }
        if let category { result = result.filter { $0.category == category } }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter { p in
                p.title.lowercased().contains(query)
                || p.body.lowercased().contains(query)
                || p.tags.contains { $0.lowercased().contains(query) }
            }
        }
        return result.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite && !$1.isFavorite }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
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

    func toggleFavorite(_ prompt: Prompt) {
        guard let idx = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        prompts[idx].isFavorite.toggle()
        prompts[idx].updatedAt = Date()
        persist()
    }

    func duplicate(_ prompt: Prompt) -> Prompt {
        var copy = prompt
        copy.id = UUID()
        copy.title = "\(prompt.title) Copy"
        copy.isCurated = false
        copy.createdAt = Date()
        copy.updatedAt = Date()
        prompts.append(copy)
        persist()
        return copy
    }

    /// Restores curated starters that are missing (keeps user prompts intact).
    func restoreCuratedStarters() {
        let existingTitles = Set(prompts.filter(\.isCurated).map(\.title))
        let missing = BundledContent.starterPrompts().filter { !existingTitles.contains($0.title) }
        guard !missing.isEmpty else { return }
        prompts.append(contentsOf: missing)
        persist()
    }

    /// Removes every prompt (used by Settings → Manage data).
    func deleteAll() {
        prompts.removeAll()
        persist()
    }

    private func persist() {
        JSONFileStore.save(prompts, to: fileName)
    }
}
