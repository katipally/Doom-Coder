// ConversationStore.swift — DoomCoder Companion (Tools)
// On-device store for the user's prompt-refine transcripts. Each Conversation is
// a full chat (rough request → refined prompt → follow-up refinements). Auto-
// saved after every exchange and reopenable to continue. Local-only — never
// synced via CloudKit. Replaces the old draft-based PromptStore.

import Foundation
import Observation
import DoomCoderCore

@MainActor
@Observable
final class ConversationStore {
    static let shared = ConversationStore()

    private let fileName = "conversations.json"
    /// Old draft file from the pre-chat build. Removed on first launch (the user
    /// confirmed a clean-slate upgrade — no migration).
    private let legacyDraftFile = "prompts.json"

    private(set) var conversations: [Conversation] = []

    private init() {
        JSONFileStore.delete(legacyDraftFile)
        if let saved = JSONFileStore.load([Conversation].self, from: fileName) {
            // Keep anything with real content (including retryable failures); drop
            // truly empty shells.
            conversations = saved.filter { !$0.isEffectivelyEmpty }
            if conversations.count != saved.count { persist() }
        }
    }

    /// Conversations, most-recently-updated first.
    var byRecent: [Conversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    func reload() {
        if let saved = JSONFileStore.load([Conversation].self, from: fileName) {
            conversations = saved.filter { !$0.isEffectivelyEmpty }
        }
    }

    func conversation(_ id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    // MARK: - Mutations

    /// Inserts or updates a conversation, stamping `updatedAt`, and persists.
    /// Empty conversations are not written to disk (no clutter from abandoned
    /// "New chat" taps), but are kept in memory so the active session stays live.
    func save(_ conversation: Conversation) {
        var updated = conversation
        updated.updatedAt = Date()
        if let idx = conversations.firstIndex(where: { $0.id == updated.id }) {
            conversations[idx] = updated
        } else {
            conversations.append(updated)
        }
        persist()
    }

    func rename(_ id: UUID, to title: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].customTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[idx].updatedAt = Date()
        persist()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        persist()
    }

    func delete(at offsets: IndexSet, in visible: [Conversation]) {
        let ids = offsets.map { visible[$0].id }
        conversations.removeAll { ids.contains($0.id) }
        persist()
    }

    /// Removes every conversation (used by Settings → Manage data).
    func deleteAll() {
        conversations.removeAll()
        persist()
    }

    private func persist() {
        // Only non-empty conversations reach disk; failed attempts count as
        // non-empty (a user message exists) so they survive relaunch and stay
        // retryable.
        JSONFileStore.save(conversations.filter { !$0.isEffectivelyEmpty }, to: fileName)
    }
}
