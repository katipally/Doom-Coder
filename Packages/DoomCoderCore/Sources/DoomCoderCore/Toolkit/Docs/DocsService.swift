// DocsService.swift — DoomCoderCore
// Loads the bundled documentation and performs deterministic keyword/BM25
// retrieval to feed the grounded AI chat. NO FoundationModels / embeddings
// dependency — retrieval works on every device, fully offline. Remote refresh is
// additive (atomic cache replace, keep last-good on validation failure).

import Foundation
import Observation

@MainActor
@Observable
public final class DocsService {
    public static let shared = DocsService()

    public private(set) var bundle: DocsBundle
    /// Set when a remote/cached bundle is newer than the baked-in baseline.
    public private(set) var loadedFrom: Source = .bundled

    public enum Source: String, Sendable { case bundled, cache, remote }

    private init() {
        self.bundle = DocsService.loadBaseline()
        // Prefer a previously cached, validated bundle if present and newer.
        if let cached = DocsService.loadCachedBundle(),
           DocsService.isAcceptable(cached) {
            self.bundle = cached
            self.loadedFrom = .cache
        }
    }

    // MARK: - Access

    public func agent(id: String) -> AgentDoc? {
        bundle.agents.first { $0.id == id }
    }

    public var agents: [AgentDoc] { bundle.agents }

    // MARK: - Retrieval (BM25-lite over sections)

    /// Returns the most relevant sections for `query`, optionally scoped to one
    /// agent. Each chunk id is "agentID#sectionIndex" so citations are stable.
    public func retrieve(query: String, agentID: String? = nil, limit: Int = 4) -> [DocChunk] {
        let qTerms = DocsService.tokenize(query)
        guard !qTerms.isEmpty else { return [] }

        let scope: [AgentDoc] = {
            if let agentID, let a = agent(id: agentID) { return [a] }
            return bundle.agents
        }()

        // Flatten to candidate documents (one per section).
        struct Candidate { let chunk: DocChunk; let terms: [String] }
        var candidates: [Candidate] = []
        for a in scope {
            for (idx, sec) in a.sections.enumerated() {
                let text = sec.heading + " " + sec.body
                let chunk = DocChunk(
                    id: "\(a.id)#\(idx)",
                    title: "\(a.title) — \(sec.heading)",
                    source: a.source,
                    text: sec.body)
                candidates.append(Candidate(chunk: chunk, terms: DocsService.tokenize(text)))
            }
        }
        guard !candidates.isEmpty else { return [] }

        // BM25 parameters.
        let k1 = 1.5, b = 0.75
        let n = Double(candidates.count)
        let avgdl = candidates.reduce(0.0) { $0 + Double($1.terms.count) } / n

        // Document frequency per query term.
        var df: [String: Int] = [:]
        for term in Set(qTerms) {
            df[term] = candidates.reduce(0) { $0 + ($1.terms.contains(term) ? 1 : 0) }
        }

        func score(_ c: Candidate) -> Double {
            var tf: [String: Int] = [:]
            for t in c.terms { tf[t, default: 0] += 1 }
            let dl = Double(c.terms.count)
            var s = 0.0
            for term in qTerms {
                guard let f = tf[term], f > 0 else { continue }
                let nq = Double(df[term] ?? 0)
                let idf = log(1 + (n - nq + 0.5) / (nq + 0.5))
                let num = Double(f) * (k1 + 1)
                let den = Double(f) + k1 * (1 - b + b * dl / max(avgdl, 1))
                s += idf * (num / den)
            }
            return s
        }

        return candidates
            .map { ($0.chunk, score($0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "/" || ch == "." {
                current.append(ch)
            } else {
                if !current.isEmpty { tokens.append(current); current = "" }
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-/")) }
            .filter { $0.count >= 2 && !Self.stopwords.contains($0) }
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "you", "your", "this", "that", "are", "can",
        "how", "what", "when", "where", "from", "into", "use", "using", "all", "any",
        "does", "did", "will", "would", "should", "could", "have", "has", "was", "were",
        "but", "not", "out", "get", "got", "via", "per", "its", "it's", "a", "an", "to",
        "of", "in", "on", "or", "is", "do", "i", "my"
    ]

    // MARK: - Loading

    private static let decoder = JSONDecoder()

    static func loadBaseline() -> DocsBundle {
        guard let url = Bundle.module.url(forResource: "docs", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let bundle = try? decoder.decode(DocsBundle.self, from: data) else {
            assertionFailure("[DocsService] Missing or invalid bundled docs.json")
            return DocsBundle(schemaVersion: DocsBundle.currentSchemaVersion, docsVersion: "0", agents: [])
        }
        return bundle
    }

    static func isAcceptable(_ b: DocsBundle) -> Bool {
        b.schemaVersion == DocsBundle.currentSchemaVersion && !b.agents.isEmpty
    }

    private static var cacheURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("docs-cache.json")
    }

    static func loadCachedBundle() -> DocsBundle? {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let bundle = try? decoder.decode(DocsBundle.self, from: data) else { return nil }
        return bundle
    }

    /// Atomically replaces the on-disk cache after validation. Returns true on
    /// success; keeps the last-good cache untouched on failure.
    @discardableResult
    public func installRemoteBundle(_ data: Data, minimumAppVersionSatisfied: Bool = true) -> Bool {
        guard let candidate = try? Self.decoder.decode(DocsBundle.self, from: data),
              Self.isAcceptable(candidate), minimumAppVersionSatisfied,
              let url = Self.cacheURL else { return false }
        do {
            try data.write(to: url, options: .atomic)
            bundle = candidate
            loadedFrom = .remote
            return true
        } catch {
            return false
        }
    }
}
