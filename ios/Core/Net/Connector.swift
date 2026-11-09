import Darwin
import dnssd
import Foundation
import os

/// TCP connections to a Mac with BSD sockets. The shared `FrameConnection` needs a file
/// descriptor, and NWConnection's Happy Eyeballs would open extra TCP connections: every
/// accepted connection is a Mac `ServerSession` that takes one of its 4 slots for 15 s and then
/// shows as a failed entry in its menu. So addresses are tried one at a time (Android `PeerConnector`).
nonisolated enum Connector {
    private static let quickTimeout: TimeInterval = 2
    private static let sameSubnetTimeout: TimeInterval = 10
    private static let otherTimeout: TimeInterval = 3
    private static let resolveTimeout: TimeInterval = 8

    /// Same subnet first, then other IPv4, then IPv6, keeping the given order otherwise. Never over
    /// mobile data: each socket is bound to a Wi-Fi/Ethernet (or hotspot) interface. Loopback and
    /// this device's own addresses stay unbound: in the Simulator the Mac is the same machine.
    /// - Parameter quick: a remembered endpoint that may be stale: 2 s per address.
    static func connect(addresses: [String], port: UInt16, quick: Bool) async throws(ClientError) -> (socket: TCPSocket, address: String) {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<(socket: TCPSocket, address: String), ClientError>, Never>) in
                // connect + poll block a thread for seconds: not one of the cooperative pool's.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Result { () throws(ClientError) in
                        try attempt(addresses, port: port, quick: quick, cancelled: cancelled)
                    })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        return try result.get()
    }

    private struct Candidate {
        let text: String
        let address: sockaddr_storage
        let length: socklen_t
        let family: Int32
        /// IP_BOUND_IF / IPV6_BOUND_IF; nil for loopback and this device's own addresses.
        let interface: UInt32?
        let sameSubnet: Bool
    }

    private static func attempt(_ addresses: [String], port: UInt16, quick: Bool, cancelled: OSAllocatedUnfairLock<Bool>) throws(ClientError) -> (socket: TCPSocket, address: String) {
        let interfaces = LocalInterface.all()
        let lan = interfaces.filter(\.isLAN)
        let candidates = addresses.enumerated()
            .compactMap { offset, text in candidate(text, port: port, interfaces: interfaces).map { (offset, $0) } }
            .sorted { lhs, rhs in
                let l = (lhs.1.sameSubnet ? 0 : 1, lhs.1.family == AF_INET ? 0 : 1, lhs.0)
                let r = (rhs.1.sameSubnet ? 0 : 1, rhs.1.family == AF_INET ? 0 : 1, rhs.0)
                return l < r
            }
            .map(\.1)
        guard !candidates.isEmpty else {
            Log.connection.warning("No usable address among \(addresses, privacy: .public)")
            throw lan.isEmpty ? .noLocalNetwork : .unreachable
        }

        var lastError = ClientError.unreachable
        for candidate in candidates {
            guard !cancelled.withLock({ $0 }) else { throw .cancelled }
            let timeout = quick ? quickTimeout : candidate.sameSubnet ? sameSubnetTimeout : otherTimeout
            Log.connection.info("Connecting to \(candidate.text, privacy: .public) port \(port) (interface \(candidate.interface.map(String.init) ?? "-", privacy: .public), same subnet: \(candidate.sameSubnet, privacy: .public))")
            let fd = socket(candidate.family, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { continue }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            if var index = candidate.interface {
                let size = socklen_t(MemoryLayout<UInt32>.size)
                _ = candidate.family == AF_INET6
                    ? setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &index, size)
                    : setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, size)
            }
            var address = candidate.address
            let length = candidate.length
            let started = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
            }
            var failure: Int32 = started == 0 ? 0 : errno
            if failure == EINPROGRESS {
                failure = waitForConnect(fd, timeout: timeout, cancelled: cancelled)
            }
            guard failure == 0 else {
                Darwin.close(fd)
                if failure == ECANCELED { throw .cancelled }
                Log.connection.warning("Connect to \(candidate.text, privacy: .public) failed: \(String(cString: strerror(failure)), privacy: .public)")
                lastError = failure == ECONNREFUSED ? .refused : .unreachable
                continue
            }
            Log.connection.info("Connected to \(candidate.text, privacy: .public)")
            let remote = candidate.family == AF_INET6 ? "[\(candidate.text)]:\(port)" : "\(candidate.text):\(port)"
            let socket = TCPSocket(fd: fd, remoteAddress: remote)
            socket.configure()
            return (socket, candidate.text)
        }
        throw lastError
    }

    /// 0 once connected, else the errno (ETIMEDOUT after `timeout`, ECANCELED when cancelled).
    private static func waitForConnect(_ fd: Int32, timeout: TimeInterval, cancelled: OSAllocatedUnfairLock<Bool>) -> Int32 {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            if cancelled.withLock({ $0 }) { return ECANCELED }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return ETIMEDOUT }
            var entry = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&entry, 1, Int32(min(remaining, 0.25) * 1000) + 1)
            if ready < 0 && errno != EINTR { return errno }
            guard ready > 0 else { continue }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return errno }
            return error
        }
    }

    /// A numeric address (IPv6 link-local with `%scope`) and how to reach it, or nil when it can't
    /// be reached without mobile data.
    private static func candidate(_ text: String, port: UInt16, interfaces: [LocalInterface]) -> Candidate? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(text, nil, &hints, &info) == 0, let first = info, let source = first.pointee.ai_addr else {
            Log.connection.warning("Ignoring malformed address \(text, privacy: .public)")
            return nil
        }
        defer { freeaddrinfo(info) }
        var storage = sockaddr_storage()
        let length = first.pointee.ai_addrlen
        withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: UnsafeRawBufferPointer(start: source, count: Int(length))) }
        let family = Int32(first.pointee.ai_family)
        var scope: UInt32 = 0
        let bytes: [UInt8] = withUnsafeMutablePointer(to: &storage) { pointer in
            if family == AF_INET6 {
                return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    sin6.pointee.sin6_port = port.bigEndian
                    scope = sin6.pointee.sin6_scope_id
                    return withUnsafeBytes(of: sin6.pointee.sin6_addr) { Array($0) }
                }
            }
            return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                sin.pointee.sin_port = port.bigEndian
                return withUnsafeBytes(of: sin.pointee.sin_addr) { Array($0) }
            }
        }
        func make(interface: UInt32?, sameSubnet: Bool) -> Candidate {
            Candidate(text: text, address: storage, length: length, family: family, interface: interface, sameSubnet: sameSubnet)
        }

        let isLoopback = family == AF_INET ? bytes[0] == 127 : bytes == [UInt8](repeating: 0, count: 15) + [1]
        if isLoopback || interfaces.contains(where: { $0.family == family && $0.address == bytes }) {
            return make(interface: nil, sameSubnet: true)
        }
        if family == AF_INET6 && bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 {
            // Link-local: only on the interface its scope names.
            guard let local = interfaces.first(where: { $0.index == scope }) else { return nil }
            if local.isLoopback { return make(interface: nil, sameSubnet: true) }
            return local.isLAN ? make(interface: scope, sameSubnet: true) : nil
        }
        let lan = interfaces.filter { $0.isLAN && $0.family == family }
        if let joined = lan.first(where: { $0.contains(bytes) }) {
            return make(interface: joined.index, sameSubnet: true)
        }
        // Another subnet: through Wi-Fi (en0) if there is one, never left to the routing table.
        guard let fallback = lan.first(where: { $0.name == "en0" }) ?? lan.first else { return nil }
        return make(interface: fallback.index, sameSubnet: false)
    }

    // MARK: - Bonjour

    /// `DNSServiceResolve(instance, _localdrop._tcp, local.)` → host and port, then
    /// `DNSServiceGetAddrInfo` → numeric addresses, IPv4 first, link-local IPv6 with `%scope`
    /// (Android `BonjourResolver`, 8 s). Opens no connection.
    static func resolve(instance: String) async throws(ClientError) -> (addresses: [String], port: UInt16) {
        let started = Date()
        let (host, port) = try await resolveService(instance: instance, timeout: resolveTimeout)
        let remaining = max(1, resolveTimeout + started.timeIntervalSinceNow)
        guard case .addresses(let addresses) = try await BonjourQuery.lookUp(host, timeout: remaining).get(), !addresses.isEmpty else {
            throw .notFound
        }
        Log.discovery.info("Resolved \(instance, privacy: .public): \(host, privacy: .public) port \(port), \(addresses.count) address(es)")
        return (addresses, port)
    }

    /// The SRV target (`MacBook-Pro.local.`) and port of a Bonjour instance.
    static func resolveService(instance: String, timeout: TimeInterval) async throws(ClientError) -> (host: String, port: UInt16) {
        guard case .service(let host, let port) = try await BonjourQuery.resolve(instance, timeout: timeout).get(), port != 0 else {
            throw .notFound
        }
        return (host, port)
    }
}

/// One address of one of this device's network interfaces.
private nonisolated struct LocalInterface {
    let name: String
    let index: UInt32
    let family: Int32
    let address: [UInt8]
    let mask: [UInt8]
    let isLoopback: Bool

    /// Wi-Fi, Ethernet (`en*`) or this iPhone's own hotspot (`bridge*`). Not cellular (`pdp_ip*`),
    /// VPN tunnels (`utun*`, `ipsec*`) or AWDL.
    var isLAN: Bool { !isLoopback && (name.hasPrefix("en") || name.hasPrefix("bridge")) }

    func contains(_ other: [UInt8]) -> Bool {
        guard other.count == address.count, mask.count == address.count else { return false }
        return zip(zip(address, mask), other).allSatisfy { pair, byte in pair.0 & pair.1 == byte & pair.1 }
    }

    static func all() -> [LocalInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            Log.connection.error("getifaddrs failed: errno \(errno)")
            return []
        }
        defer { freeifaddrs(head) }
        func bytes(_ address: UnsafeMutablePointer<sockaddr>) -> [UInt8] {
            if Int32(address.pointee.sa_family) == AF_INET6 {
                return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
            }
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
        }
        return sequence(first: first, next: { $0.pointee.ifa_next }).compactMap { pointer in
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, let address = entry.ifa_addr else { return nil }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { return nil }
            return LocalInterface(
                name: String(cString: entry.ifa_name),
                index: if_nametoindex(entry.ifa_name),
                family: family,
                address: bytes(address),
                mask: entry.ifa_netmask.map(bytes) ?? [],
                isLoopback: flags & IFF_LOOPBACK != 0
            )
        }
    }
}

/// One dnssd query on its own serial queue, answered once: by its result, an error, the deadline
/// or cancellation.
private nonisolated final class BonjourQuery: @unchecked Sendable {
    enum Answer: Sendable {
        case service(host: String, port: UInt16)
        case addresses([String])
    }

    // Everything below is confined to `queue`.
    private let queue = DispatchQueue(label: "dev.localdrop.bonjour")
    private var ref: DNSServiceRef?
    private var continuation: CheckedContinuation<Result<Answer, ClientError>, Never>?
    private var done = false
    private var addresses: [String] = []
    private var settling = false

    static func resolve(_ instance: String, timeout: TimeInterval) async -> Result<Answer, ClientError> {
        await run(timeout: timeout) { context in
            var ref: DNSServiceRef?
            let error = DNSServiceResolve(&ref, 0, 0, instance, ProtocolConstants.bonjourServiceType, "local.", { _, _, _, errorCode, _, hosttarget, port, _, _, context in
                guard let context else { return }
                Unmanaged<BonjourQuery>.fromOpaque(context).takeUnretainedValue()
                    .resolved(errorCode, host: hosttarget.map { String(cString: $0) }, port: UInt16(bigEndian: port))
            }, context)
            return (error, ref)
        }
    }

    static func lookUp(_ host: String, timeout: TimeInterval) async -> Result<Answer, ClientError> {
        await run(timeout: timeout) { context in
            var ref: DNSServiceRef?
            let protocols = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
            let error = DNSServiceGetAddrInfo(&ref, 0, 0, protocols, host, { _, flags, _, errorCode, _, address, _, context in
                guard let context else { return }
                Unmanaged<BonjourQuery>.fromOpaque(context).takeUnretainedValue().found(errorCode, flags: flags, address: address)
            }, context)
            return (error, ref)
        }
    }

    /// Starts the query on `queue`; the query object stays alive through the deadline closure.
    private static func run(
        timeout: TimeInterval,
        _ start: @escaping @Sendable (UnsafeMutableRawPointer) -> (DNSServiceErrorType, DNSServiceRef?)
    ) async -> Result<Answer, ClientError> {
        let query = BonjourQuery()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                query.queue.async {
                    guard !query.done else { return continuation.resume(returning: .failure(.cancelled)) }
                    query.continuation = continuation
                    let (error, ref) = start(Unmanaged.passUnretained(query).toOpaque())
                    guard error == kDNSServiceErr_NoError, let ref else {
                        Log.discovery.error("Bonjour query failed to start: \(error)")
                        return query.finish(.failure(error == kDNSServiceErr_PolicyDenied ? .localNetworkDenied : .notFound))
                    }
                    query.ref = ref
                    DNSServiceSetDispatchQueue(ref, query.queue)
                    query.queue.asyncAfter(deadline: .now() + timeout) { query.finish(.failure(.notFound)) }
                }
            }
        } onCancel: {
            query.queue.async { query.finish(.failure(.cancelled)) }
        }
    }

    private func resolved(_ error: DNSServiceErrorType, host: String?, port: UInt16) {
        guard error == kDNSServiceErr_NoError, let host else {
            Log.discovery.info("Bonjour resolve failed: \(error)")
            // Local Network access is off: saying the Mac isn't there would send the user looking for it.
            return finish(.failure(error == kDNSServiceErr_PolicyDenied ? .localNetworkDenied : .notFound))
        }
        finish(.success(.service(host: host, port: port)))
    }

    private func found(_ error: DNSServiceErrorType, flags: DNSServiceFlags, address: UnsafePointer<sockaddr>?) {
        // Errors here are per address family (no AAAA record, say): the other may still answer.
        if error == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let address {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                var text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if text.hasPrefix("::ffff:") { text.removeFirst(7) }
                if !addresses.contains(text) { addresses.append(text) }
            }
        }
        guard flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0, !addresses.isEmpty, !settling else { return }
        // IPv4 and IPv6 answers come separately: a moment for the other family.
        settling = true
        queue.asyncAfter(deadline: .now() + 0.3) { [self] in
            finish(.success(.addresses(addresses.filter { !$0.contains(":") } + addresses.filter { $0.contains(":") })))
        }
    }

    private func finish(_ result: Result<Answer, ClientError>) {
        guard !done else { return }
        done = true
        if let ref {
            DNSServiceRefDeallocate(ref)
            self.ref = nil
        }
        continuation?.resume(returning: result)
        continuation = nil
    }
}
