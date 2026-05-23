// NetworkInterfaces.swift — macOS LAN introspection helper.
// Provides the primary active IPv4 interface's MAC address and broadcast
// IPv4 so the iOS companion can send a Wake-on-LAN magic packet over the
// local subnet when DoomCoder is asleep AND the phone is on the same Wi-Fi.
// Cellular WoL is impossible by design (no link-layer broadcast); APNs
// "Wake for network access" remains the canonical remote-wake path.

import Foundation
import Darwin

enum NetworkInterfaces {

    /// Returns (macAddress, broadcastIPv4) of the first up, non-loopback
    /// interface with an IPv4 address — typically `en0` (Wi-Fi) or `en1`
    /// (Ethernet). Either tuple element may be nil if the system call fails.
    static func primaryWoLDescriptor() -> (macAddress: String?, broadcastIPv4: String?) {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            return (nil, nil)
        }
        defer { freeifaddrs(ifaddrPtr) }

        // First pass: find a candidate IPv4 interface (en*).
        var candidateName: String?
        var broadcast: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let name = String(cString: p.pointee.ifa_name)
            let flags = Int32(p.pointee.ifa_flags)
            let family = p.pointee.ifa_addr?.pointee.sa_family
            if (flags & IFF_UP) != 0,
               (flags & IFF_LOOPBACK) == 0,
               family == UInt8(AF_INET),
               name.hasPrefix("en"),
               let dst = p.pointee.ifa_dstaddr {
                var addr = dst.pointee
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let r = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                                    &host, socklen_t(host.count),
                                    nil, 0, NI_NUMERICHOST)
                    }
                }
                if r == 0 {
                    candidateName = name
                    let nullIdx = host.firstIndex(of: 0) ?? host.endIndex
                    broadcast = String(decoding: host[..<nullIdx].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    break
                }
            }
            ptr = p.pointee.ifa_next
        }

        guard let iface = candidateName else { return (nil, nil) }

        // Second pass: look up the MAC (AF_LINK) for the chosen interface.
        var mac: String?
        ptr = first
        while let p = ptr {
            let name = String(cString: p.pointee.ifa_name)
            let family = p.pointee.ifa_addr?.pointee.sa_family
            if name == iface, family == UInt8(AF_LINK), let sa = p.pointee.ifa_addr {
                sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    let len = Int(dl.pointee.sdl_alen)
                    guard len == 6 else { return }
                    let base = UnsafeRawPointer(dl) + 20 + Int(dl.pointee.sdl_nlen)
                    let bytes = base.assumingMemoryBound(to: UInt8.self)
                    mac = (0..<6).map { String(format: "%02x", bytes[$0]) }.joined(separator: ":")
                }
                if mac != nil { break }
            }
            ptr = p.pointee.ifa_next
        }

        return (mac, broadcast)
    }
}
