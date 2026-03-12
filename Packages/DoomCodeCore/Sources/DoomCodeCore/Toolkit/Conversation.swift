// Conversation.swift — DoomCodeCore
// Shared, local-only chat transcript models powering the redesigned Prompt
// workspace on BOTH the macOS app and the iOS companion. A Conversation is an
// ordered transcript of the user's rough requests and the AI's refined prompts.
// Pure-Foundation, Codable & Sendable value types with NO CloudKit / iCloud
// coupling — prompt history lives only on the device that created it.

import Foundation

// MARK: - Chat message

/// Who authored a transcript message.
public enum ChatRole: String, Codable, Sendable, Hashable {
    case user
    case assistant
}

/// Delivery/generation state of a message. Only assistant messages are ever
/// `.streaming`, `.failed`, or `.cancelled`; user messages are always `.complete`.
public enum ChatMessageStatus: String, Codable, Sendable, Hashable {
    case complete
    case streaming
    case failed
    case cancelled
}

/// A single transcript message: a user's rough request, or the AI's refined
/// prompt. Assistant messages carry the tier that produced them and a status so
/// the UI can render spinners, streamed text, and inline retry affordances.
public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var role: ChatRole
    public var text: String
    /// Which backend produced an assistant message (nil for user messages).
    public var tier: AITier?
    public var status: ChatMessageStatus
    /// Stored error message for a `.failed` assistant message, so the UI can show
    /// actionable guidance after relaunch without re-running anything.
    public var errorText: String?
    public var createdAt: Date

    public init(id: UUID = UUID(),
                role: ChatRole,
                text: String = "",
                tier: AITier? = nil,
                status: ChatMessageStatus = .complete,
                errorText: String? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.tier = tier
        self.status = status
        self.errorText = errorText
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, tier, status, errorText, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decodeIfPresent(ChatRole.self, forKey: .role) ?? .user
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        tier = try c.decodeIfPresent(AITier.self, forKey: .tier)
        // A message persisted mid-stream is treated as failed on reload — there is
        // no live task to resume, so the user can simply retry.
        let decoded = try c.decodeIfPresent(ChatMessageStatus.self, forKey: .status) ?? .complete
        status = (decoded == .streaming) ? .failed : decoded
        errorText = try c.decodeIfPresent(String.self, forKey: .errorText)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    public var isUser: Bool { role == .user }
    public var isAssistant: Bool { role == .assistant }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Conversation

/// A saved, local-only refine transcript. Auto-saved after every exchange and
/// reopenable to continue refining. Title is auto-derived from the first user
/// message but can be renamed by the user.
public struct Conversation: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// User-set title. When empty, `displayTitle` derives one from the first
    /// user message.
    public var customTitle: String
    public var messages: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                customTitle: String = "",
                messages: [ChatMessage] = [],
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.customTitle = customTitle
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, customTitle, messages, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle) ?? ""
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// The most recent completed assistant prompt, if any (used for "copy last").
    public var lastAssistantText: String? {
        messages.last { $0.role == .assistant && $0.status == .complete }?.trimmedText
    }

    /// First user message text, used to derive a title when none is set.
    public var firstUserText: String {
        messages.first { $0.role == .user }?.trimmedText ?? ""
    }

    /// Title shown in History. Explicit title wins; otherwise the first line of
    /// the first user message, truncated; otherwise a default.
    public var displayTitle: String {
        let explicit = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        let firstLine = firstUserText
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstLine.isEmpty else { return "New prompt" }
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }

    /// Short preview (the latest refined prompt or the first user message).
    public var preview: String {
        lastAssistantText ?? firstUserText
    }

    /// True when nothing worth keeping exists: no user text and no assistant
    /// content. A conversation with a user message and a *failed* attempt is NOT
    /// empty — it is retryable and must be preserved.
    public var isEffectivelyEmpty: Bool {
        !messages.contains { !$0.trimmedText.isEmpty }
    }

    /// Transcript turns suitable for feeding an AI engine (drops empty/in-flight
    /// placeholder assistant messages and trims whitespace).
    public func engineTranscript() -> [AIChatTurn] {
        messages.compactMap { msg in
            let t = msg.trimmedText
            guard !t.isEmpty else { return nil }
            // Skip failed/cancelled assistant attempts — they aren't valid context.
            if msg.role == .assistant && msg.status != .complete { return nil }
            return AIChatTurn(role: msg.role, text: t)
        }
    }
}
