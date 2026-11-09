import Foundation
import Network
import Observation

/// A Mac seen on Bonjour (`_localdrop._tcp`, instance name = the Mac's deviceId).
nonisolated struct BrowsedMac: Identifiable, Hashable, Sendable {
    /// The instance name as published.
    let id: String
    /// The instance name lowercased when it is a UUID. A renamed instance ("<uuid> (2)", after a
    /// name conflict) gives nil: then only `server_hello.id` tells which Mac it is.
    let deviceId: String?
    /// The SRV target made readable ("MacBook-Pro-Zeppon.local." → "MacBook Pro Zeppon"): the
    /// only name there is before the handshake. Arrives a moment after the Mac appears.
    let hostName: String?
}

/// Continuous Bonjour browse for the Add a Mac list. Browsing and resolving open no TCP
/// connection, so the Macs it lists see nothing until the user picks one. Bonjour carries no
/// mode information: whether a Mac is open for pairing shows only in the handshake.
@MainActor @Observable final class BonjourBrowser {
    /// De-duplicated by instance name: the same Mac shows on several interfaces.
    private(set) var macs: [BrowsedMac] = []
    /// False while browsing fails, e.g. without the local network permission.
    private(set) var isAvailable = true

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var hostNames: [String: String] = [:]
    @ObservationIgnored private var resolving: Set<String> = []

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: ProtocolConstants.bonjourServiceType, domain: "local."), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    self?.isAvailable = true
                case .waiting(let error), .failed(let error):
                    Log.discovery.warning("Bonjour browse unavailable: \(error.localizedDescription, privacy: .public)")
                    self?.isAvailable = false
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return name
            }
            MainActor.assumeIsolated { self?.update(names) }
        }
        self.browser = browser
        browser.start(queue: .main)
        Log.discovery.info("Bonjour browse started")
    }

    func stop() {
        browser?.cancel()
        browser = nil
        macs = []
        Log.discovery.info("Bonjour browse stopped")
    }

    private func update(_ names: [String]) {
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }.sorted()
        macs = unique.map { name in
            BrowsedMac(id: name, deviceId: UUID(uuidString: name) != nil ? name.lowercased() : nil, hostName: hostNames[name])
        }
        for name in unique where hostNames[name] == nil && !resolving.contains(name) {
            resolving.insert(name)
            Task { [weak self] in
                let host = try? await Connector.resolveService(instance: name, timeout: 5).host
                guard let self else { return }
                resolving.remove(name)
                guard let host else { return }
                var pretty = host
                for suffix in [".local.", ".local", "."] where pretty.hasSuffix(suffix) {
                    pretty.removeLast(suffix.count)
                    break
                }
                hostNames[name] = pretty.replacingOccurrences(of: "-", with: " ")
                macs = macs.map { $0.id == name ? BrowsedMac(id: name, deviceId: $0.deviceId, hostName: hostNames[name]) : $0 }
            }
        }
    }
}
