// WakeOnLAN.swift — DoomCoder Companion
// Broadcasts a Wake-on-LAN magic packet via POSIX UDP socket on port 9.
// Uses Network framework NWPathMonitor to gate the call on Wi-Fi availability.
// The Network framework's NWConnection does not expose SO_BROADCAST, so we
// fall back to a raw BSD socket with setsockopt(SO_BROADCAST).

import Foundation
import Network

// MARK: - Error type

enum WakeOnLANError: Error, LocalizedError {
    case notOnWifi
    case sendFailed(String)
    case noProfile

    var errorDescription: String? {
        switch self {
        case .notOnWifi:      return "Wake-on-LAN requires a Wi-Fi connection."
        case .sendFailed(let m): return "Magic packet send failed: \(m)"
        case .noProfile:      return "No Wake-on-LAN profile found for this Mac."
        }
    }
}

// MARK: - WakeOnLAN

enum WakeOnLAN {

    /// Sends a magic packet for every supplied MAC address string.
    /// Throws `WakeOnLANError.notOnWifi` when the current path is cellular-only.
    static func wake(macAddresses: [String]) async throws {
        // Gate on Wi-Fi.
        try await requireWiFi()

        for addressString in macAddresses {
            let packet = try magicPacket(for: addressString)
            try sendPacket(packet)
        }
    }

    // MARK: - Internals

    /// Blocks until NWPathMonitor reports at least one satisfying path status.
    private static func requireWiFi() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let monitor = NWPathMonitor()
            let q = DispatchQueue(label: "wol.pathmonitor")
            var finished = false
            monitor.pathUpdateHandler = { path in
                guard !finished else { return }
                finished = true
                monitor.cancel()
                if path.usesInterfaceType(.wifi) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: WakeOnLANError.notOnWifi)
                }
            }
            monitor.start(queue: q)
        }
    }

    /// Constructs the 102-byte WoL magic packet:
    /// 6 × 0xFF followed by 16 repetitions of the 6-byte MAC address.
    private static func magicPacket(for macAddress: String) throws -> Data {
        let bytes = macAddress
            .split(separator: ":")
            .compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else {
            throw WakeOnLANError.sendFailed("Invalid MAC address: \(macAddress)")
        }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet // 6 + 96 = 102 bytes
    }

    /// Sends `packet` via a POSIX UDP socket with SO_BROADCAST to 255.255.255.255:9.
    private static func sendPacket(_ packet: Data) throws {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            throw WakeOnLANError.sendFailed("socket() failed: errno \(errno)")
        }
        defer { close(sock) }

        // Enable broadcast.
        var broadcast: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

        // Allow address reuse.
        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family      = sa_family_t(AF_INET)
        addr.sin_port        = UInt16(9).bigEndian
        addr.sin_addr.s_addr = INADDR_BROADCAST

        let sent = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(sock, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else {
            throw WakeOnLANError.sendFailed("sendto() returned \(sent), errno \(errno)")
        }
    }
}
