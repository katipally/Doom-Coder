// AgentNotificationPrefs.swift — Doom Coder (Mac)
//
// Per-agent notification preferences. Replaces the single global
// `ChannelStore.NotificationPrefs`: every tracked agent now has its own
// independent set of choices, seeded from smart minimal defaults.
//
// The gate (`shouldNotify`) is the one place that decides whether a normalized
// hook event becomes a user-facing notification. It runs at dispatch time
// (AgentTrackingManager.ingest) — hooks still *capture* every event so live
// status / Dynamic Island stay accurate; only the alert is gated here.
//
// Classifiers for tools and approval kinds come from
// `AgentNotificationCatalog`, so the editor UI and this gate never drift.

import Foundation

enum ToolTrigger: String, Codable, Sendable, CaseIterable {
    case started      // notify on .toolStart
    case finished     // notify on .toolEnd
    case both
}

struct AgentNotificationPrefs: Codable, Equatable, Sendable {
    // Top-level category switches. Defaults here are the "minimal smart" set
    // applied to a brand-new agent; `defaults(for:)` tailors sub-selections.
    var completed: Bool = true            // .sessionEnd
    var failed: Bool = true               // .error / .toolError
    var waitingApproval: Bool = true      // .permissionNeeded (filtered by approvalKinds)
    var waitingInput: Bool = false        // .agentResponse
    var sessionStart: Bool = false        // .sessionStart
    var subagentActivity: Bool = false    // .subagentStart / .subagentEnd
    var toolCalls: Bool = false           // .toolStart / .toolEnd

    // Opt-in coverage categories (all default OFF). Surface events that were
    // previously dropped to `.other` and never notifiable.
    var fileEdits: Bool = false           // .fileEdit
    var contextCompaction: Bool = false   // .compaction
    var agentThinking: Bool = false       // .thinking
    var housekeeping: Bool = false        // .housekeeping
    var userPromptSent: Bool = false      // .userPrompt

    // Tool-call sub-options.
    var toolWhen: ToolTrigger = .finished
    /// Allowed `ToolOption.id`s. `nil` = all tools allowed (the default once
    /// the user flips Tool calls on without narrowing it).
    var enabledTools: Set<String>? = nil

    /// Allowed `ApprovalKind.id`s. Seeded by `defaults(for:)` to the agent's
    /// non-noisy kinds so routine pre-exec gating (Cursor shell/MCP) stays quiet.
    var approvalKinds: Set<String> = []

    // MARK: - Codable (non-destructive merge)
    //
    // Swift's synthesized decoder THROWS on a missing key even when the property
    // has a default value (verified). A custom `init(from:)` using
    // `decodeIfPresent ?? default` lets older on-disk JSON — which lacks the
    // newer coverage categories — decode successfully, preserving every existing
    // user choice and defaulting brand-new keys to OFF. This replaces a
    // version-bump-and-reseed migration, which would have wiped user choices.

    enum CodingKeys: String, CodingKey {
        case completed, failed, waitingApproval, waitingInput, sessionStart
        case subagentActivity, toolCalls
        case fileEdits, contextCompaction, agentThinking, housekeeping, userPromptSent
        case toolWhen, enabledTools, approvalKinds
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        completed         = try c.decodeIfPresent(Bool.self, forKey: .completed)         ?? true
        failed            = try c.decodeIfPresent(Bool.self, forKey: .failed)            ?? true
        waitingApproval   = try c.decodeIfPresent(Bool.self, forKey: .waitingApproval)   ?? true
        waitingInput      = try c.decodeIfPresent(Bool.self, forKey: .waitingInput)      ?? false
        sessionStart      = try c.decodeIfPresent(Bool.self, forKey: .sessionStart)      ?? false
        subagentActivity  = try c.decodeIfPresent(Bool.self, forKey: .subagentActivity)  ?? false
        toolCalls         = try c.decodeIfPresent(Bool.self, forKey: .toolCalls)         ?? false
        fileEdits         = try c.decodeIfPresent(Bool.self, forKey: .fileEdits)         ?? false
        contextCompaction = try c.decodeIfPresent(Bool.self, forKey: .contextCompaction) ?? false
        agentThinking     = try c.decodeIfPresent(Bool.self, forKey: .agentThinking)     ?? false
        housekeeping      = try c.decodeIfPresent(Bool.self, forKey: .housekeeping)      ?? false
        userPromptSent    = try c.decodeIfPresent(Bool.self, forKey: .userPromptSent)    ?? false
        toolWhen          = try c.decodeIfPresent(ToolTrigger.self, forKey: .toolWhen)   ?? .finished
        enabledTools      = try c.decodeIfPresent(Set<String>.self, forKey: .enabledTools)
        approvalKinds     = try c.decodeIfPresent(Set<String>.self, forKey: .approvalKinds) ?? []
    }

    // MARK: - Defaults

    /// Smart minimal defaults for a freshly-installed agent.
    static func defaults(for agent: TrackedAgent) -> AgentNotificationPrefs {
        var p = AgentNotificationPrefs()
        let supported = Set(AgentNotificationCatalog.categories(for: agent))
        // Only enable categories the agent can actually emit.
        p.completed       = supported.contains(.completed)
        p.failed          = supported.contains(.failed)
        p.waitingApproval = supported.contains(.waitingApproval)
        // Seed approvals to the genuine (non-noisy) kinds only.
        p.approvalKinds = Set(
            AgentNotificationCatalog.approvalKinds(for: agent)
                .filter { !$0.noisy }
                .map(\.id)
        )
        return p
    }

    // MARK: - Enabled-category query

    /// Whether the top-level switch for `id` is ON. Mirrors `binding(for:)` in
    /// NotifyAboutCard — the single source of truth for "is this category on".
    func isEnabled(_ id: NotifCategoryID) -> Bool {
        switch id {
        case .completed:         return completed
        case .failed:            return failed
        case .waitingApproval:   return waitingApproval
        case .waitingInput:      return waitingInput
        case .sessionStart:      return sessionStart
        case .toolCalls:         return toolCalls
        case .subagentActivity:  return subagentActivity
        case .fileEdits:         return fileEdits
        case .contextCompaction: return contextCompaction
        case .agentThinking:     return agentThinking
        case .housekeeping:      return housekeeping
        case .userPromptSent:    return userPromptSent
        }
    }

    /// The agent's supported categories that are currently switched ON, in
    /// catalog display order. Drives the read-only iOS "what you'll be notified
    /// about" list.
    func enabledCategories(for agent: TrackedAgent) -> [NotifCategoryID] {
        AgentNotificationCatalog.categories(for: agent).filter { isEnabled($0) }
    }

    // MARK: - The gate

    /// Decides whether a normalized event should fire a notification for `agent`.
    func shouldNotify(_ ev: NormalizedHookEvent) -> Bool {
        switch ev.phase {
        case .sessionEnd:
            // Closing an agent is not "task completed" — it fires right after a
            // real turn-end event and double-notifies. Gate it on the
            // default-off housekeeping switch instead. The phase stays
            // `.sessionEnd` so session finalization is unaffected.
            if AgentNotificationCatalog.isSessionClose(for: ev.agent, rawEvent: ev.rawEvent) {
                return housekeeping
            }
            return completed
        case .error, .toolError:
            return failed
        case .sessionStart:
            return sessionStart
        case .agentResponse:
            return waitingInput
        case .subagentStart, .subagentEnd:
            return subagentActivity

        case .permissionNeeded:
            guard waitingApproval else { return false }
            let kind = AgentNotificationCatalog.approvalKindID(
                for: ev.agent, rawEvent: ev.rawEvent, toolName: ev.toolName)
            return approvalKinds.contains(kind)

        case .toolStart, .toolEnd:
            guard toolCalls else { return false }
            // Honor the start/finished/both trigger.
            switch toolWhen {
            case .started:  if ev.phase != .toolStart { return false }
            case .finished: if ev.phase != .toolEnd { return false }
            case .both:     break
            }
            // Honor the per-tool allowlist (nil = all).
            guard let allowed = enabledTools else { return true }
            let toolID = AgentNotificationCatalog.toolOptionID(
                forToolName: ev.toolName ?? "")
            return allowed.contains(toolID)

        case .userPrompt:
            return userPromptSent
        case .fileEdit:
            return fileEdits
        case .compaction:
            return contextCompaction
        case .thinking:
            return agentThinking
        case .housekeeping:
            return housekeeping
        case .other:
            return false
        }
    }
}

// MARK: - Store

enum AgentNotificationStore {
    private static let key = "doomcoder.notification.prefs.perAgent.v1"
    private static let migrationKey = "doomcoder.notification.prefs.perAgent.migrated.v1"

    /// One-time seed of smart defaults for every agent. Mirrors the old
    /// `ChannelStore.migratePrefsIfNeeded()` launch hook.
    static func migrateIfNeeded() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: migrationKey) else { return }
        var map: [String: AgentNotificationPrefs] = [:]
        for agent in TrackedAgent.allCases {
            map[agent.rawValue] = .defaults(for: agent)
        }
        save(map)
        ud.set(true, forKey: migrationKey)
    }

    static func loadAll() -> [String: AgentNotificationPrefs] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: AgentNotificationPrefs].self, from: data)
        else { return [:] }
        return decoded
    }

    static func save(_ map: [String: AgentNotificationPrefs]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Saved prefs for the agent, or freshly-seeded defaults if none exist.
    static func prefs(for agent: TrackedAgent) -> AgentNotificationPrefs {
        loadAll()[agent.rawValue] ?? .defaults(for: agent)
    }

    static func setPrefs(_ prefs: AgentNotificationPrefs, for agent: TrackedAgent) {
        var map = loadAll()
        map[agent.rawValue] = prefs
        save(map)
    }
}
