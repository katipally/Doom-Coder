// DocsModels.swift — DoomCoderCore
// Shared, Codable documentation models for the Reference tab (full docs + AI chat).
// A baseline `docs.json` is bundled in the package (Bundle.module) so the feature
// works fully offline on first run. A remote pull can later replace the cache as
// long as `schemaVersion` matches and `minimumAppVersion` is satisfied.

import Foundation

/// One heading + body passage inside an agent's documentation.
public struct DocSection: Codable, Sendable, Hashable, Identifiable {
    /// Stable per-agent index assigned at load time ("0", "1", …). Not decoded.
    public var id: String
    public var heading: String
    public var body: String

    public init(id: String = UUID().uuidString, heading: String, body: String) {
        self.id = id
        self.heading = heading
        self.body = body
    }

    private enum CodingKeys: String, CodingKey { case heading, body }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID().uuidString
        heading = try c.decode(String.self, forKey: .heading)
        body = try c.decode(String.self, forKey: .body)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(heading, forKey: .heading)
        try c.encode(body, forKey: .body)
    }
}

/// Full documentation for a single tracked agent.
public struct AgentDoc: Codable, Sendable, Hashable, Identifiable {
    /// Matches `TrackedAgent.rawValue` (e.g. "claude", "copilot_cli").
    public var id: String
    public var title: String
    public var tagline: String
    public var source: String?
    public var sections: [DocSection]

    public init(id: String, title: String, tagline: String, source: String? = nil, sections: [DocSection]) {
        self.id = id
        self.title = title
        self.tagline = tagline
        self.source = source
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey { case id, title, tagline, source, sections }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        tagline = try c.decodeIfPresent(String.self, forKey: .tagline) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source)
        // Assign stable per-agent section ids at load time.
        let raw = try c.decode([DocSection].self, forKey: .sections)
        sections = raw.enumerated().map { idx, s in
            DocSection(id: "\(idx)", heading: s.heading, body: s.body)
        }
    }
}

/// The versioned envelope shipped as `docs.json`.
public struct DocsBundle: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var docsVersion: String
    public var minimumAppVersion: String?
    public var updatedAt: String?
    public var agents: [AgentDoc]

    public init(schemaVersion: Int, docsVersion: String, minimumAppVersion: String? = nil, updatedAt: String? = nil, agents: [AgentDoc]) {
        self.schemaVersion = schemaVersion
        self.docsVersion = docsVersion
        self.minimumAppVersion = minimumAppVersion
        self.updatedAt = updatedAt
        self.agents = agents
    }

    /// The schema this app build understands. A remote bundle is rejected if its
    /// `schemaVersion` differs.
    public static let currentSchemaVersion = 1
}
