// BundledContent.swift — DoomCoder Companion (Tools)
// Loads the curated, bundled JSON content shipped inside the app: starter prompt
// templates and the CLI cheat sheets. All offline.

import Foundation
import DoomCoderCore

enum BundledContent {

    /// Curated starter prompts seeded on first launch.
    static func starterPrompts() -> [Prompt] {
        decode([Prompt].self, resource: "starter_prompts") ?? []
    }

    private static func decode<T: Decodable>(_ type: T.Type, resource: String) -> T? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            assertionFailure("[BundledContent] Missing bundled resource: \(resource).json")
            return nil
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            assertionFailure("[BundledContent] Failed to decode \(resource).json: \(error)")
            return nil
        }
    }
}
