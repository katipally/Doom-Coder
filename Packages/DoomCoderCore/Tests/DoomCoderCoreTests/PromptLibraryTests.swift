import Foundation
import Testing
@testable import DoomCoderCore

@Suite("PromptLibrary")
struct PromptLibraryTests {
    @Test func shipsAGenerousSetOfCuratedPrompts() {
        #expect(PromptLibrary.all.count >= 20)
        #expect(PromptLibrary.all.allSatisfy { $0.isCurated })
    }

    @Test func everyPromptHasTitleAndBody() {
        for prompt in PromptLibrary.all {
            #expect(!prompt.title.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!prompt.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test func titlesAreUnique() {
        let titles = PromptLibrary.all.map(\.title)
        #expect(Set(titles).count == titles.count)
    }

    @Test func placeholdersRenderToBracketsWhenEmpty() {
        // A copied prompt with no values filled must never leave raw {{tokens}}.
        for prompt in PromptLibrary.all {
            let rendered = prompt.render(values: [:])
            #expect(!rendered.contains("{{"))
            #expect(!rendered.contains("}}"))
        }
    }

    @Test func groupedCoversEveryPromptExactlyOnce() {
        let grouped = PromptLibrary.grouped().flatMap { $0.prompts }
        #expect(grouped.count == PromptLibrary.all.count)
    }
}
