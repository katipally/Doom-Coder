import Foundation
import Darwin
import OSLog
import DoomCoderCore

/// Captures the Mac's hardware MAC addresses + the WoMP (`pmset -g | grep
/// womp`) flag and uploads them as a `WoLProfile` CloudKit record so the
/// iOS companion can wake this Mac via a magic-packet broadcast when on the
/// same LAN.
///
/// Called on launch and whenever the network interfaces change.
@MainActor
enum WoLProfileExporter {

    private static let logger = Logger(subsystem: "com.doomcoder", category: "wol")

    static func publish() {
        let macs = collectMACAddresses()
        let womp = wakeForNetworkAccessEnabled()
        let rec = WoLProfileRecord(
            macId: CloudKitSyncEngine.shared.macId,
            macName: CloudKitSyncEngine.shared.macName,
            macAddresses: macs,
            lanSSIDs: [],   // CoreWLAN SSID capture deferred (needs Location permission)
            wakeForNetworkAccessEnabled: womp,
            lastSeenAt: Date()
        )
        CloudKitSyncEngine.shared.publishWoLProfile(rec)
        logger.info("WoL profile published: macs=\(macs.count) womp=\(womp)")
    }

    /// Enumerates every non-loopback interface and returns its 6-byte MAC
    /// address formatted as `aa:bb:cc:dd:ee:ff`.
    private static func collectMACAddresses() -> [String] {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
        defer { freeifaddrs(addrs) }

        var out: Set<String> = []
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cur {
            let ifa = ptr.pointee
            defer { cur = ifa.ifa_next }
            guard let sa = ifa.ifa_addr else { continue }
            guard sa.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: ifa.ifa_name)
            if name == "lo0" { continue }
            let sdl = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_dl.self)
            let alen = Int(sdl.pointee.sdl_alen)
            guard alen == 6 else { continue }
            // sdl_data is a flexible array: name + alen address bytes
            let nlen = Int(sdl.pointee.sdl_nlen)
            var bytes = [UInt8](repeating: 0, count: 6)
            let dataPtr = withUnsafePointer(to: sdl.pointee.sdl_data) {
                UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self)
            }
            for i in 0..<6 { bytes[i] = (dataPtr + nlen + i).pointee }
            let str = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
            if str != "00:00:00:00:00:00" {
                out.insert(str)
            }
        }
        return Array(out).sorted()
    }

    /// Reads `pmset -g` and returns true if `womp 1`.
    private static func wakeForNetworkAccessEnabled() -> Bool {
        let pipe = Pipe()
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = ["-g"]
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("womp") {
                return trimmed.contains(" 1")
            }
        }
        return false
    }
}
