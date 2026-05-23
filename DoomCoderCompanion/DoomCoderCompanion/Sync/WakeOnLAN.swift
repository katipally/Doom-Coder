// WakeOnLAN.swift — Companion app local-subnet wake.
//
// Sends a Wake-on-LAN "magic packet" (6×0xFF + 16×MAC) as UDP broadcast on
// port 9 when the user toggles a Setting while the Mac is asleep AND on the
// same LAN. Over cellular the packet has nowhere to go — that case relies on
// CloudKit silent push + the Mac's built-in "Wake for network access" (APNs
// proxy). Cheap, idempotent best-effort: failure logs but never blocks the
// UI write path.

import Foundation
import Darwin
import os.log

enum WakeOnLAN {

    private static let logger = Logger(subsystem: "com.doomcoder.companion", category: "wol")

    /// Sends 3 magic packets back-to-back (50 ms apart) to maximize the chance
    /// of one surviving a flaky Wi-Fi handoff. Synchronous; returns true if
    /// the socket sends succeeded.
    @discardableResult
    static func wake(macAddress: String, broadcastIPv4: String) -> Bool {
        guard let mac = parseMAC(macAddress) else {
            logger.error("invalid MAC: \(macAddress, privacy: .public)")
            return false
        }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: mac) }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            logger.error("socket() failed")
            return false
        }
        defer { close(fd) }

        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            logger.error("SO_BROADCAST failed: \(String(cString: strerror(errno)), privacy: .public)")
            return false
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(9).bigEndian
        guard inet_pton(AF_INET, broadcastIPv4, &addr.sin_addr) == 1 else {
            logger.error("invalid broadcast IP: \(broadcastIPv4, privacy: .public)")
            return false
        }

        var anyOk = false
        for _ in 0..<3 {
            let sent = packet.withUnsafeBytes { raw -> Int in
                withUnsafePointer(to: &addr) { sa in
                    sa.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                        sendto(fd, raw.baseAddress, packet.count, 0, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent == packet.count {
                anyOk = true
            } else {
                logger.notice("sendto short: \(sent) errno=\(errno)")
            }
            usleep(50_000)
        }
        if anyOk {
            logger.info("magic packet sent → \(broadcastIPv4, privacy: .public) (MAC \(macAddress, privacy: .public))")
        }
        return anyOk
    }

    private static func parseMAC(_ s: String) -> [UInt8]? {
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard p.count == 2, let v = UInt8(p, radix: 16) else { return nil }
            out.append(v)
        }
        return out
    }
}
