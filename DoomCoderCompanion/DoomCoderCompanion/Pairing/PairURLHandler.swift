// PairURLHandler.swift — DoomCoder Companion
// Pure parser for doomcoder://pair?... URLs. Returns a typed value or nil
// on malformed input. Used by the AppDelegate's URL handler and by the
// QR scanner fallback path.

import Foundation
import DoomCoderCore

public struct ParsedPairURL: Equatable, Sendable {
    public let shareURL: URL
    public let containerIdentifier: String
}

public enum PairURLHandler {

    public static func parse(url: URL) -> ParsedPairURL? {
        guard url.scheme == "doomcoder", url.host == "pair" else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        guard let shareURLString = items.first(where: { $0.name == "ckShareURL" })?.value,
              let shareURL = URL(string: shareURLString),
              shareURL.host == "www.icloud.com"
        else { return nil }
        let container = items.first(where: { $0.name == "container" })?.value
            ?? CloudKitConstants.containerIdentifier
        return ParsedPairURL(
            shareURL: shareURL,
            containerIdentifier: container
        )
    }
}
