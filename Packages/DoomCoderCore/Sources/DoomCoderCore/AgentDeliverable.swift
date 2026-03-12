// AgentDeliverable.swift — DoomCoderCore
//
// A single, fully-rendered "what you'll be notified about" row, synced
// Mac → iOS inside `AgentConfigRecord`. The Mac is the single source of
// truth for the copy: it filters each agent's notification categories to the
// ones the user has enabled (in the "What you'll be notified about" editor)
// and ships the resulting title/symbol/detail rows. iOS renders them read-only.
//
// Shipping rendered rows (rather than category IDs) means the iOS app needs no
// copy of the Mac-only `AgentNotificationCatalog`, and new categories added on
// the Mac surface on older iOS builds without an app update.

import Foundation

public struct AgentDeliverable: Sendable, Equatable, Codable, Identifiable {
    /// Stable identity for SwiftUI `ForEach` — the SF Symbol + title pair is
    /// unique within an agent's list.
    public var id: String { symbol + "|" + title }

    public let title: String
    /// SF Symbol name.
    public let symbol: String
    /// One-line description shown under the title.
    public let detail: String

    public init(title: String, symbol: String, detail: String) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
    }
}
