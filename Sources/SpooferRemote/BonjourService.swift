import Darwin
import Foundation
@preconcurrency import Network
import RemoteAPI
import SystemConfiguration

/// Bonjour advertising for the remote server, and the address helpers used
/// to tell people where to point the iPhone when Bonjour can't reach it.
public enum BonjourService {
    /// The Mac's name from System Settings ▸ General ▸ Sharing.
    public static var computerName: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        return ProcessInfo.processInfo.hostName
    }

    /// The `_iosgpsspoof._tcp` record the listener publishes. Its TXT record
    /// carries the server ID (so the iPhone recognises a paired Mac under any
    /// name) and the Mac's IPv4 addresses as a fallback.
    public static func service(name: String, serverID: String, port: UInt16) -> NWListener.Service {
        // Bonjour instance names are limited to 63 bytes of UTF-8.
        var serviceName = name.isEmpty ? "iOS GPS Spoofer" : name
        while serviceName.utf8.count > 63 { serviceName.removeLast() }
        let addresses = localIPv4Addresses().prefix(4).map(\.address).joined(separator: ",")
        let txt = NWTXTRecord([
            RemoteAPI.TXTKey.version: String(RemoteAPI.version),
            RemoteAPI.TXTKey.serverID: serverID,
            RemoteAPI.TXTKey.name: String(name.prefix(60)),
            RemoteAPI.TXTKey.addresses: addresses,
            RemoteAPI.TXTKey.port: String(port),
        ])
        return NWListener.Service(name: serviceName, type: RemoteAPI.serviceType, domain: nil, txtRecord: txt)
    }

    public struct LocalAddress: Sendable, Hashable {
        public let interface: String
        public let address: String

        /// "Personal Hotspot", "Wi-Fi or Ethernet", …
        public var label: String {
            if address.hasPrefix("172.20.10.") { return "iPhone Personal Hotspot" }
            if interface.hasPrefix("bridge") { return "Internet Sharing" }
            if interface.hasPrefix("en") { return "Wi-Fi or Ethernet (\(interface))" }
            return interface
        }
    }

    /// IPv4 addresses of the interfaces that are up, skipping loopback and
    /// self-assigned (169.254.x.x) ones.
    public static func localIPv4Addresses() -> [LocalAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [LocalAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = entry.ifa_flags
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            guard !address.hasPrefix("169.254.") else { continue }
            let item = LocalAddress(interface: String(cString: entry.ifa_name), address: address)
            if !result.contains(item) { result.append(item) }
        }
        return result
    }

    /// Whether a connecting peer is on the local network: loopback, private
    /// (RFC 1918), carrier-grade NAT, link-local or unique-local IPv6.
    /// Anything else is refused before a byte is read.
    public static func isLocalNetwork(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return isLocal(ipv4: Array(address.rawValue))
        case .ipv6(let address):
            let bytes = Array(address.rawValue)
            // Global IPv6 addresses count when they share the Mac's /64.
            return isLocal(ipv6: bytes) || localIPv6Prefixes().contains(Array(bytes.prefix(8)))
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    /// The /64 prefixes of the Mac's own IPv6 addresses.
    static func localIPv6Prefixes() -> Set<[UInt8]> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var prefixes = Set<[UInt8]>()
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = pointer.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET6) else { continue }
            let socket = UnsafeRawPointer(addr).load(as: sockaddr_in6.self)
            prefixes.insert(withUnsafeBytes(of: socket.sin6_addr) { Array($0.prefix(8)) })
        }
        return prefixes
    }

    static func isLocal(ipv4 b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (127, _), (10, _), (192, 168), (169, 254):
            return true
        case (172, 16...31):
            return true
        case (100, 64...127):
            return true
        default:
            return false
        }
    }

    static func isLocal(ipv6 b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }       // ::1
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }                  // fe80::/10
        if (b[0] & 0xfe) == 0xfc { return true }                                  // fc00::/7
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {  // ::ffff:a.b.c.d
            return isLocal(ipv4: Array(b[12..<16]))
        }
        return false
    }
}
