import Darwin
import dnssd
import Foundation

/// Local TCP listener on a system-chosen port, also published over Bonjour (`_localdrop._tcp`).
/// Restarts itself after a failure (e.g. network interface reset).
@Observable
final class TCPListener {
    enum State: Equatable {
        case stopped
        case starting
        case ready(port: UInt16)
        case waiting(reason: String)
        case failed(reason: String)
    }

    private(set) var state: State = .stopped

    /// Receives every accepted connection; the handler owns the socket. Called on the main queue.
    var onConnection: ((TCPSocket) -> Void)?
    /// Called on every state transition.
    var onStateChange: ((State) -> Void)?

    private let bonjourName: String
    private var listener: DispatchSourceRead?
    private var bonjour: DNSServiceRef?
    private var restartTask: Task<Void, Never>?
    private static let restartDelay: Duration = .seconds(3)

    /// Port to try first: the one used last time, so paired phones can reconnect to their
    /// remembered endpoint after a restart without Bluetooth. Falls back to any free port.
    private var preferredPort: UInt16?
    private static let portKey = "localdrop.listenerPort"

    init(bonjourName: String) {
        self.bonjourName = bonjourName
        let saved = UserDefaults.standard.integer(forKey: Self.portKey)
        preferredPort = (1024...65535).contains(saved) ? UInt16(saved) : nil
    }

    var port: UInt16? {
        if case .ready(let port) = state { return port }
        return nil
    }

    func start() {
        guard listener == nil else { return }
        restartTask?.cancel()
        restartTask = nil
        update(.starting)

        let fd: Int32
        let port: UInt16
        do {
            (fd, port) = try Self.listen(on: preferredPort)
        } catch let error as ListenError where preferredPort != nil && error.code == EADDRINUSE {
            // The remembered port is taken; any port works, phones fall back to discovery.
            Log.connection.warning("Port \(self.preferredPort ?? 0) unavailable; using any port")
            preferredPort = nil
            update(.stopped)
            start()
            return
        } catch {
            Log.connection.error("Failed to create TCP listener: \(error.localizedDescription, privacy: .public)")
            update(.failed(reason: error.localizedDescription))
            scheduleRestart()
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptPending(fd) }
        }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source
        source.resume()
        publish(port: port)

        Log.connection.info("TCP listener ready on port \(port, privacy: .public)")
        UserDefaults.standard.set(Int(port), forKey: Self.portKey)
        update(.ready(port: port))
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        listener?.cancel()
        listener = nil
        if let bonjour {
            DNSServiceRefDeallocate(bonjour)
            self.bonjour = nil
        }
        update(.stopped)
    }

    /// A dual-stack socket listening on all interfaces, so it survives network changes.
    private static func listen(on preferred: UInt16?) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw ListenError(code: errno, step: "socket") }
        func fail(_ step: String) -> ListenError {
            let error = ListenError(code: errno, step: step)
            Darwin.close(fd)
            return error
        }
        var off: Int32 = 0
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_any
        address.sin6_port = (preferred ?? 0).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0 else { throw fail("bind") }
        guard Darwin.listen(fd, 16) == 0 else { throw fail("listen") }
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw fail("fcntl") }

        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw fail("getsockname") }
        return (fd, UInt16(bigEndian: address.sin6_port))
    }

    private func acceptPending(_ listenFd: Int32) {
        while true {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let fd = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listenFd, $0, &length) }
            }
            guard fd >= 0 else {
                if errno != EWOULDBLOCK && errno != EINTR && errno != ECONNABORTED {
                    Log.connection.error("accept failed: \(String(cString: strerror(errno)), privacy: .public)")
                }
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            let socket = TCPSocket(fd: fd, remoteAddress: Self.describe(address))
            socket.configure()
            accept(socket)
        }
    }

    private func accept(_ socket: TCPSocket) {
        Log.connection.info("Incoming connection from \(socket.remoteAddress, privacy: .public)")
        guard let onConnection else {
            Log.connection.error("No connection handler installed; dropping connection")
            socket.close()
            return
        }
        onConnection(socket)
    }

    /// Advertises the port as `_localdrop._tcp` with this Mac's name.
    private func publish(port: UInt16) {
        if let bonjour {
            DNSServiceRefDeallocate(bonjour)
            self.bonjour = nil
        }
        var ref: DNSServiceRef?
        let error = DNSServiceRegister(
            &ref, 0, 0, bonjourName, ProtocolConstants.bonjourServiceType, nil, nil,
            port.bigEndian, 0, nil, nil, nil
        )
        guard error == kDNSServiceErr_NoError, let ref else {
            Log.connection.error("Bonjour registration failed: \(error, privacy: .public)")
            return
        }
        DNSServiceSetDispatchQueue(ref, .main)
        bonjour = ref
    }

    /// A NUL-terminated C string buffer as a String.
    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `a.b.c.d:port` for IPv4 (also when it arrives as an IPv4-mapped IPv6 address).
    private static func describe(_ storage: sockaddr_storage) -> String {
        var storage = storage
        let length = socklen_t(storage.ss_len)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let result = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), &service, socklen_t(service.count), NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard result == 0 else { return "unknown" }
        var address = Self.string(host)
        if address.hasPrefix("::ffff:") { address.removeFirst(7) }
        let port = Self.string(service)
        return address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    private func scheduleRestart() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: Self.restartDelay)
            guard !Task.isCancelled, let self, self.listener == nil else { return }
            Log.connection.info("Restarting TCP listener")
            self.start()
        }
    }

    private func update(_ newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }
}

private nonisolated struct ListenError: LocalizedError {
    let code: Int32
    let step: String

    var errorDescription: String? { "\(step): \(String(cString: strerror(code)))" }
}

/// An accepted, connected TCP socket. Whoever receives it closes it, usually by handing it to
/// `FrameConnection`.
nonisolated struct TCPSocket: Sendable {
    let fd: Int32
    /// `address:port` of the peer, for logs and the connection list.
    let remoteAddress: String

    /// The address without the port.
    var remoteHost: String {
        if remoteAddress.hasPrefix("["), let end = remoteAddress.firstIndex(of: "]") {
            return String(remoteAddress[remoteAddress.index(after: remoteAddress.startIndex)..<end])
        }
        return remoteAddress.split(separator: ":").first.map(String.init) ?? remoteAddress
    }

    /// Low latency for small messages, a dead peer noticed within ~25 s, and EPIPE instead of
    /// SIGPIPE when writing to a closed connection.
    func configure() {
        var on: Int32 = 1
        var idle: Int32 = 10
        var interval: Int32 = 5
        var count: Int32 = 3
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, size)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, size)
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &count, size)
    }

    func close() {
        Darwin.close(fd)
    }
}
