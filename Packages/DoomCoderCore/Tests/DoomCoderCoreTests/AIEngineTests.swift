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

@Suite("AIEngineSelection")
struct AIEngineSelectionTests {
    @Test func exposesExactlyOnDeviceAndRemoteKey() {
        #expect(AIEngineSelection.allCases == [.appleOnDevice, .remoteKey])
    }

    @Test func tiersAreOnDeviceAndRemoteKey() {
        #expect(Set(AITier.allCases) == [.appleOnDevice, .remoteKey])
    }
}
