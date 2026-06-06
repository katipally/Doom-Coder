// PairURLHandler.swift — DoomCoder Companion
// Pure parser for doomcoder://pair?... URLs. Returns a typed value or nil
// on malformed input. Used by the AppDelegate's URL handler and by the
// QR scanner fallback path.

import Foundation
import DoomCoderCore

public enum ParsedPairURL: Equatable, Sendable {
    /// Different-Apple-ID pairing — carries a CKShare URL to accept.
    case ckShare(shareURL: URL, containerIdentifier: String)
    /// Same-iCloud pairing — no CKShare; resolves to the Mac's identity and
    /// drives the ConnectionStateChange handshake directly.
    case sameICloud(macId: String, macUserRecordID: String)
}

public enum PairURLHandler {

    public static func parse(url: URL) -> ParsedPairURL? {
        guard url.scheme == "doomcoder", url.host == "pair" else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []

        // Same-iCloud variant: doomcoder://pair?sameICloud=1&macId=…&macUser=…
        if items.first(where: { $0.name == "sameICloud" })?.value == "1" {
            guard let macId = items.first(where: { $0.name == "macId" })?.value, !macId.isEmpty,
                  let macUser = items.first(where: { $0.name == "macUser" })?.value, !macUser.isEmpty
            else { return nil }
            return .sameICloud(macId: macId, macUserRecordID: macUser)
        }

        // Different-iCloud (CKShare) variant.
        guard let shareURLString = items.first(where: { $0.name == "ckShareURL" })?.value,
              let shareURL = URL(string: shareURLString),
              shareURL.host == "www.icloud.com"
        else { return nil }
        let container = items.first(where: { $0.name == "container" })?.value
            ?? CloudKitConstants.containerIdentifier
        return .ckShare(shareURL: shareURL, containerIdentifier: container)
    }
}
