import CoreWLAN
import Darwin
import Foundation

/// Band of the Wi-Fi network this Mac is joined to.
nonisolated enum WiFiBand: Equatable, Sendable {
    case ghz2_4
    case ghz5
    case ghz6
}

/// Enumerates LAN addresses that a peer on the same Wi-Fi/Ethernet network can reach.
nonisolated enum NetworkInterfaces {
    /// nil when Wi-Fi is off, not joined, or the band is unknown. The band needs no location
    /// permission (unlike the network name), so it is read without asking.
    static func wifiBand() -> WiFiBand? {
        guard let channel = CWWiFiClient.shared().interface()?.wlanChannel() else { return nil }
        return switch channel.channelBand {
        case .band2GHz: .ghz2_4
        case .band5GHz: .ghz5
        case .band6GHz: .ghz6
        case .bandUnknown: nil
        @unknown default: nil
        }
    }

    /// IPv4 first, then IPv6. Excludes loopback, link-local IPv6 (needs a scope id the peer
    /// doesn't know) and virtual interfaces (VPN tunnels, AWDL, bridges).
    static func lanAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            Log.connection.error("getifaddrs failed: errno \(errno)")
            return []
        }
        defer { freeifaddrs(head) }

        var ipv4: [String] = []
        var ipv6: [String] = []

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.ifa_addr else { continue }

            let interfaceName = String(cString: entry.ifa_name)
            guard interfaceName.hasPrefix("en") else { continue }

            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                if let text = numericHost(address, length: socklen_t(MemoryLayout<sockaddr_in>.size)) {
                    ipv4.append(text)
                }
            case AF_INET6:
                let isLinkLocal = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    sin6.pointee.sin6_addr.__u6_addr.__u6_addr8.0 == 0xFE
                        && (sin6.pointee.sin6_addr.__u6_addr.__u6_addr8.1 & 0xC0) == 0x80
                }
                if !isLinkLocal,
                   let text = numericHost(address, length: socklen_t(MemoryLayout<sockaddr_in6>.size)) {
                    ipv6.append(text)
                }
            default:
                continue
            }
        }
        return Array(NSOrderedSet(array: ipv4 + ipv6)) as? [String] ?? ipv4 + ipv6
    }

    private static func numericHost(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        guard result == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
