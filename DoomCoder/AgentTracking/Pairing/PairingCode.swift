// PairingCode.swift — DoomCoder Mac
// A short, human-typeable code shown on the Mac alongside a QR code so the
// iPhone user can either scan the QR or type the code in by hand. The code
// is a 6-character Crockford base32 string (no I/L/O/0/1) computed from a
// fresh 32-bit random nonce. It's NOT a secret; the security boundary is
// Apple's CKShare acceptance, not the code.

import Foundation
import DoomCoderCore

public struct PairingCode: Codable, Sendable, Equatable, Hashable {
    public let code: String
    public let nonce: UInt32
    public let createdAt: Date
    public let expiresAt: Date

    public static let lifetime: TimeInterval = 600

    public init(nonce: UInt32 = UInt32.random(in: 0..<UInt32.max)) {
        self.nonce = nonce
        self.createdAt = Date()
        self.expiresAt = Date().addingTimeInterval(Self.lifetime)
        self.code = Self.encode(nonce: nonce)
    }

    public init(code: String, createdAt: Date, expiresAt: Date) {
        self.code = code
        self.nonce = Self.decode(code: code) ?? 0
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool { Date() > expiresAt }

    /// The deep-link URL the iPhone opens. Apple accepts CKShare URLs via
    /// CKContainer.accept([shareMeta]) on the iOS side, but the iOS app
    /// first routes through this doomcoder:// scheme so we can show our
    /// own confirmation dialog before the system share sheet.
    public var pairURL: URL? {
        var components = URLComponents()
        components.scheme = "doomcoder"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "nonce", value: String(nonce))
        ]
        return components.url
    }

    // MARK: - Crockford base32 (no I, L, O, U; no 0, 1)

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func encode(nonce: UInt32) -> String {
        // 6 chars * 5 bits = 30 bits, plenty for a 32-bit nonce.
        var n = nonce & 0x3FFF_FFFF
        var out = ""
        out.reserveCapacity(6)
        for _ in 0..<6 {
            let idx = Int(n & 0x1F)
            out.append(alphabet[idx])
            n >>= 5
        }
        return String(out.reversed())
    }

    static func decode(code: String) -> UInt32? {
        let cleaned = code.uppercased()
        guard cleaned.count == 6 else { return nil }
        var value: UInt32 = 0
        for char in cleaned {
            guard let idx = alphabet.firstIndex(of: char) else { return nil }
            value = (value << 5) | UInt32(idx)
        }
        return value
    }
}
