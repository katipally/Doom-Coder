// DeviceID.swift — DoomCoderCore
// Stable per-device identifier. Used as the macId/iosId foreign key on
// Connection and as the macId on every record Mac writes to CloudKit.

import Foundation

public typealias DeviceID = String

public enum DeviceIDFactory {
    /// Cryptographically random, URL-safe, 22-character identifier.
    public static func make() -> DeviceID {
        // 16 random bytes -> 22-char base64url (no padding). Cryptographically
        // unique; collision probability is effectively zero for any plausible
        // fleet size of paired devices.
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Validates that a string is a syntactically well-formed DeviceID. Used by
    /// boundary code (e.g. URL parameter parsing) to reject bad input early.
    public static func isValid(_ id: DeviceID) -> Bool {
        guard !id.isEmpty, id.count == 22 else { return false }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return id.allSatisfy(allowed.contains)
    }
}
