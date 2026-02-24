import Foundation
import Testing
@testable import DoomCoderCore

@Suite("TemplateValidator")
struct TemplateValidatorTests {

    @Test func normalizesLooseTokensToSnakeCase() {
        let t = TemplateValidator.validate(
            title: "Test",
            category: "tests",
            body: "Write tests for {{ Target File }} in {{language}} covering {{edge-Cases}}.",
            fields: [])
        #expect(t != nil)
        let keys = Prompt.placeholderKeys(in: t!.body)
        #expect(keys == ["target_file", "language", "edge_cases"])
        // Every token has a matching field.
        #expect(Set(t!.fields.map(\.key)) == Set(keys))
    }

    @Test func rejectsNestedBraces() {
        let t = TemplateValidator.validate(
            title: "X", category: "general",
            body: "Broken {{outer {{inner}} }} token.", fields: [])
        #expect(t == nil)
    }

    @Test func rejectsUnmatchedBraces() {
        let t = TemplateValidator.validate(
            title: "X", category: "general",
            body: "Dangling {{open token here", fields: [])
        #expect(t == nil)
    }

    @Test func coercesUnknownCategoryToGeneral() {
        let t = TemplateValidator.validate(
            title: "X", category: "totally-made-up",
            body: "Do {{thing}}.", fields: [])
        #expect(t?.category == .general)
    }

    @Test func capsExcessiveFields() {
        let tokens = (0..<20).map { "{{field_\($0)}}" }.joined(separator: " ")
        let t = TemplateValidator.validate(title: "X", category: "general", body: tokens, fields: [])
        #expect(t == nil) // beyond maxFields -> caller falls back
    }

    @Test func derivesFieldMetadataFromParsedBodyNotModelClaims() {
        // Model claims a field 'ghost' that isn't in the body; it must be ignored.
        let t = TemplateValidator.validate(
            title: "X", category: "debug",
            body: "Fix {{error_log}}.",
            fields: [ComposedField(key: "ghost", label: "Ghost", hint: "nope", multiline: false)])
        #expect(t != nil)
        #expect(t!.fields.map(\.key) == ["error_log"])
        #expect(t!.fields.first?.multiline == true) // 'log' -> multiline heuristic
    }

    @Test func mergesModelHintsByNormalizedKey() {
        let t = TemplateValidator.validate(
            title: "X", category: "general",
            body: "Use {{api_key}}.",
            fields: [ComposedField(key: "API Key", label: "Your API Key", hint: "secret", multiline: false)])
        #expect(t?.fields.first?.label == "Your API Key")
        #expect(t?.fields.first?.hint == "secret")
    }
}

@Suite("HeuristicEngine")
struct HeuristicEngineTests {
    let engine = HeuristicEngine()

    @Test func enhanceProducesStructuredPrompt() async {
        let r = await engine.enhance("write tests for my parser")
        #expect(r.value?.contains("Task:") == true)
        #expect(r.tier == .heuristic)
    }

    @Test func composeProducesValidTemplate() async {
        let r = await engine.compose(intent: "refactor my networking layer")
        let template = r.value
        #expect(template != nil)
        #expect(template?.category == .refactor)
        // Body tokens all resolve to fields.
        let keys = Prompt.placeholderKeys(in: template!.body)
        #expect(Set(keys) == Set(template!.fields.map(\.key)))
    }

    @Test func chatStaysGroundedAndCitesOnlySuppliedChunks() async {
        let chunks = [
            DocChunk(id: "a", title: "Claude Code", text: "Use /clear to reset the conversation."),
            DocChunk(id: "b", title: "Cursor", text: "Cmd+K edits inline.")
        ]
        let r = await engine.chat(question: "how do I reset?", context: chunks)
        let answer = r.value
        #expect(answer != nil)
        // Citations must be a subset of supplied chunk ids.
        #expect(answer!.citations.allSatisfy { ["a", "b"].contains($0.chunkID) })
    }

    @Test func chatWithNoContextDoesNotHallucinate() async {
        let r = await engine.chat(question: "anything", context: [])
        #expect(r.value?.citations.isEmpty == true)
    }
}

@Suite("AIResult")
struct AIResultTests {
    @Test func actionableFailuresAreClassified() {
        #expect(AIFailure.network("x").isActionable == true)
        #expect(AIFailure.missingKey.isActionable == true)
        #expect(AIFailure.rateLimited.isActionable == true)
        #expect(AIFailure.malformed.isActionable == false)
        #expect(AIFailure.safetyRefusal.isActionable == false)
        #expect(AIFailure.unavailable(.deviceNotEligible).isActionable == false)
    }
}

@Suite("DocsService")
@MainActor
struct DocsServiceTests {
    @Test func bundledDocsLoadForAllSixAgents() {
        let ids = Set(DocsService.shared.agents.map(\.id))
        for agent in ["claude", "codex_cli", "copilot_cli", "cursor", "vscode", "windsurf"] {
            #expect(ids.contains(agent), "Missing bundled docs for \(agent)")
        }
        #expect(!ids.contains("gemini"), "Gemini CLI should be dropped")
    }

    @Test func retrievalScopesToAgentAndReturnsStableChunkIDs() {
        let chunks = DocsService.shared.retrieve(query: "approval sandbox mode", agentID: "codex_cli", limit: 3)
        #expect(!chunks.isEmpty)
        for c in chunks {
            #expect(c.id.hasPrefix("codex_cli#"), "Chunk \(c.id) escaped the agent scope")
        }
    }

    @Test func retrievalRanksRelevantSectionFirst() {
        let chunks = DocsService.shared.retrieve(query: "slash commands compact context", agentID: "claude", limit: 4)
        #expect(chunks.first?.title.localizedCaseInsensitiveContains("slash") == true)
    }

    @Test func emptyQueryReturnsNothing() {
        #expect(DocsService.shared.retrieve(query: "   ", agentID: "claude").isEmpty)
    }
}
