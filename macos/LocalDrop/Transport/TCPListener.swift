import Foundation
import Network

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

    /// Receives every accepted connection. Called on the main queue.
    var onConnection: ((NWConnection) -> Void)?
    /// Called on every state transition.
    var onStateChange: ((State) -> Void)?

    private let bonjourName: String
    private var listener: NWListener?
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

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            let port = preferredPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
            listener = try NWListener(using: parameters, on: port)
        } catch {
            Log.connection.error("Failed to create TCP listener: \(error.localizedDescription, privacy: .public)")
            update(.failed(reason: error.localizedDescription))
            scheduleRestart()
            return
        }

        listener.service = NWListener.Service(name: bonjourName, type: ProtocolConstants.bonjourServiceType)
        listener.stateUpdateHandler = { [weak self] newState in
            MainActor.assumeIsolated { self?.handle(newState) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }

        self.listener = listener
        update(.starting)
        listener.start(queue: .main)
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        listener?.cancel()
        listener = nil
        update(.stopped)
    }

    private func handle(_ newState: NWListener.State) {
        switch newState {
        case .setup:
            break
        case .ready:
            guard let port = listener?.port?.rawValue else {
                Log.connection.error("Listener ready without a port")
                update(.failed(reason: "Listener has no port"))
                return
            }
            Log.connection.info("TCP listener ready on port \(port, privacy: .public)")
            UserDefaults.standard.set(Int(port), forKey: Self.portKey)
            update(.ready(port: port))
        case .waiting(let error):
            Log.connection.warning("TCP listener waiting: \(error.localizedDescription, privacy: .public)")
            update(.waiting(reason: error.localizedDescription))
        case .failed(let error) where preferredPort != nil && state == .starting:
            // The remembered port is taken; any port works, phones fall back to discovery.
            Log.connection.warning("Port \(self.preferredPort ?? 0) unavailable (\(error.localizedDescription, privacy: .public)); using any port")
            preferredPort = nil
            listener?.cancel()
            listener = nil
            start()
            return
        case .failed(let error):
            Log.connection.error("TCP listener failed: \(error.localizedDescription, privacy: .public)")
            listener?.cancel()
            listener = nil
            update(.failed(reason: error.localizedDescription))
            scheduleRestart()
        case .cancelled:
            Log.connection.info("TCP listener cancelled")
        @unknown default:
            Log.connection.warning("TCP listener entered an unknown state")
        }
    }

    private func accept(_ connection: NWConnection) {
        Log.connection.info("Incoming connection from \(String(describing: connection.endpoint), privacy: .public)")
        guard let onConnection else {
            Log.connection.error("No connection handler installed; dropping connection")
            connection.cancel()
            return
        }
        onConnection(connection)
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
