import Foundation

/// Maps a hardware identifier (`utsname.machine`, e.g. "iPhone17,1") to its
/// marketing name (e.g. "iPhone 16 Pro"). Used as the default device name on
/// iOS/iPadOS, where `UIDevice.current.name` returns a generic "iPhone" since
/// iOS 16 without the Apple-approval-gated `user-assigned-device-name`
/// entitlement.
///
/// Deliberately `enum` with `static` members and no UIKit import so it is
/// `nonisolated` and usable from any context (including the NSE) without
/// MainActor hops. Unknown identifiers fall back to a friendly family label
/// derived from the identifier prefix.
public enum DeviceModelName {

    /// The current device's hardware identifier (`utsname.machine`). On the
    /// Simulator this returns the host arch, so we prefer the
    /// `SIMULATOR_MODEL_IDENTIFIER` env var when present.
    public static var currentIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !sim.isEmpty {
            return sim
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partial.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier
    }

    /// Marketing name for the current device (e.g. "iPhone 16 Pro").
    public static var current: String { marketingName(for: currentIdentifier) }

    /// Marketing name for an arbitrary hardware identifier, with a graceful
    /// family-label fallback for identifiers not in the table.
    public static func marketingName(for identifier: String) -> String {
        if let name = table[identifier] { return name }
        return familyFallback(for: identifier)
    }

    /// Friendly family label for an unknown identifier ("iPhone15,99" → "iPhone").
    private static func familyFallback(for identifier: String) -> String {
        if identifier.hasPrefix("iPhone") { return "iPhone" }
        if identifier.hasPrefix("iPad")   { return "iPad" }
        if identifier.hasPrefix("iPod")   { return "iPod touch" }
        if identifier.hasPrefix("Mac")    { return "Mac" }
        if identifier.hasPrefix("Watch")  { return "Apple Watch" }
        if identifier.hasPrefix("AudioAccessory") { return "HomePod" }
        if identifier.hasPrefix("AppleTV") { return "Apple TV" }
        return identifier.isEmpty ? "Device" : identifier
    }

    /// Identifier → marketing name. Covers recent iPhone/iPad hardware; extend
    /// as new models ship (unknowns degrade to the family label).
    static let table: [String: String] = [
        // iPhone 12
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        // iPhone 13
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd generation)",
        // iPhone 14
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        // iPhone 15
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        // iPhone 16
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        // iPhone 17
        "iPhone18,3": "iPhone 17",
        "iPhone18,4": "iPhone 17 Plus",
        "iPhone18,1": "iPhone 17 Pro",
        "iPhone18,2": "iPhone 17 Pro Max",

        // iPad Pro (M4)
        "iPad16,3": "iPad Pro 11-inch (M4)",
        "iPad16,4": "iPad Pro 11-inch (M4)",
        "iPad16,5": "iPad Pro 13-inch (M4)",
        "iPad16,6": "iPad Pro 13-inch (M4)",
        // iPad Air (M2)
        "iPad14,8": "iPad Air 11-inch (M2)",
        "iPad14,9": "iPad Air 11-inch (M2)",
        "iPad14,10": "iPad Air 13-inch (M2)",
        "iPad14,11": "iPad Air 13-inch (M2)",
        // iPad (10th gen) / mini
        "iPad13,18": "iPad (10th generation)",
        "iPad13,19": "iPad (10th generation)",
        "iPad14,1": "iPad mini (6th generation)",
        "iPad14,2": "iPad mini (6th generation)",
    ]
}
