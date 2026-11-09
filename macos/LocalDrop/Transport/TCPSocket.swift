import Darwin

/// A connected TCP socket, accepted by `TCPListener` or opened by a client. Whoever receives it
/// closes it, usually by handing it to `FrameConnection`.
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
