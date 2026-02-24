// JSONFileStore.swift — DoomCoder Companion (Tools)
// Tiny Codable-to-JSON persistence helper for the on-device tool data
// (prompts, notes). Writes to the app's Application Support directory —
// app-private, NOT the App Group (this data is local-only and never shared with
// the Notification Service Extension).

import Foundation

enum JSONFileStore {
    private static let folderName = "DoomCoderTools"

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func load<T: Decodable>(_ type: T.Type, from fileName: String) -> T? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to fileName: String) {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func exists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
    }

    static func delete(_ fileName: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }
}
