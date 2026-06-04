// Route.swift — DoomCoderCore
// A Route describes HOW two paired devices exchange data. The current model
// has two cases:
//   - .iCloud: implicit, same Apple ID, no explicit user action required
//   - .ckShare: explicit, different Apple IDs, user pairs via a CKShare URL
//
// The Route enum is Codable so it can be stored in UserDefaults and in
// Connection records. Adding a new route (e.g. a future self-hosted relay)
// is a non-breaking change because existing decoders fall back to .iCloud
// for unknown tags.

import Foundation

public enum Route: Codable, Sendable, Equatable, Hashable {
    case iCloud
    case ckShare(CKShareRef)

    public enum Tag: String, Codable, Sendable {
        case iCloud
        case ckShare
    }

    public var tag: Tag {
        switch self {
        case .iCloud:    return .iCloud
        case .ckShare:   return .ckShare
        }
    }

    public var displayName: String {
        switch self {
        case .iCloud:
            return "iCloud (same Apple ID)"
        case .ckShare:
            return "iCloud Share (different Apple ID)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .iCloud:   return "iCloud"
        case .ckShare:  return "iCloud Share"
        }
    }

    public var isCrossAppleID: Bool {
        if case .ckShare = self { return true }
        return false
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case tag, ref }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .tag)
        switch tag {
        case .iCloud:
            self = .iCloud
        case .ckShare:
            let ref = try c.decode(CKShareRef.self, forKey: .ref)
            self = .ckShare(ref)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tag, forKey: .tag)
        if case let .ckShare(ref) = self {
            try c.encode(ref, forKey: .ref)
        }
    }
}

/// Reference to a CloudKit share. `shareURLString` is the share-acceptance
/// URL Apple returns when a CKShare is created. We persist it as a String
/// rather than a URL because URL is not Sendable in Swift 6 strict
/// concurrency, and CKShare.URL is itself not Codable.
public struct CKShareRef: Codable, Sendable, Equatable, Hashable {
    public let shareURLString: String
    public let ownerRecordName: String
    public let containerIdentifier: String

    public init(shareURL: URL, ownerRecordName: String, containerIdentifier: String) {
        self.shareURLString = shareURL.absoluteString
        self.ownerRecordName = ownerRecordName
        self.containerIdentifier = containerIdentifier
    }

    public init(shareURLString: String, ownerRecordName: String, containerIdentifier: String) {
        self.shareURLString = shareURLString
        self.ownerRecordName = ownerRecordName
        self.containerIdentifier = containerIdentifier
    }

    public var shareURL: URL? {
        URL(string: shareURLString)
    }

    /// Defensive URL parser used by the iOS pairing flow.
    public static func make(shareURLString: String, containerIdentifier: String) -> CKShareRef? {
        guard let url = URL(string: shareURLString),
              !url.absoluteString.isEmpty,
              !containerIdentifier.isEmpty
        else { return nil }
        return CKShareRef(
            shareURLString: url.absoluteString,
            ownerRecordName: url.absoluteString,
            containerIdentifier: containerIdentifier
        )
    }
}
