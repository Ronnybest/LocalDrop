import CoreBluetooth
import Foundation

/// BLE peripheral: advertises the LocalDrop service and serves the Endpoint Info characteristic
/// (protocol/protocol.md §2). Used only for discovery; no file data ever goes over BLE.
@Observable
final class BLEAdvertiser: NSObject {
    enum State: Equatable {
        case idle
        case starting
        case advertising
        case poweredOff
        case unauthorized
        case unsupported
        case failed(reason: String)
    }

    private(set) var state: State = .idle

    /// Current local name: the rotating private token, or the pairing-mode name.
    private let nameProvider: () -> String
    /// Current Endpoint Info characteristic value (open or sealed), or nil when the TCP listener isn't ready.
    private let endpointValueProvider: () -> Data?
    /// Pending-delivery UUIDs, one per phone with files waiting (protocol.md §2.8); advertised
    /// instead of the service UUID, taking turns when there are several.
    private let pendingProvider: () -> [CBUUID]
    private var advertisedName = ""
    /// The pending-delivery UUID on air, nil for the service UUID.
    private var advertisedPending: CBUUID?
    private var pendingTurn = 0
    private var turnTimer: Timer?
    private static let turnInterval: TimeInterval = 3

    private var manager: CBPeripheralManager?
    private var service: CBMutableService?
    private var wantsAdvertising = false
    /// Snapshot served across a long (multi-request) GATT read so the bytes stay consistent.
    private var pendingReadValue: Data?

    init(nameProvider: @escaping () -> String, endpointValueProvider: @escaping () -> Data?, pendingProvider: @escaping () -> [CBUUID]) {
        self.nameProvider = nameProvider
        self.endpointValueProvider = endpointValueProvider
        self.pendingProvider = pendingProvider
        super.init()
    }

    /// Re-reads the name (token slot changed, pairing mode toggled) and the pending state, and
    /// re-advertises if either changed.
    func refresh() {
        guard let manager, wantsAdvertising, manager.state == .poweredOn, service != nil else { return }
        guard nameProvider() != advertisedName || currentPending() != advertisedPending else { return }
        manager.stopAdvertising()
        // `isAdvertising` still reads true right after stopping, so don't go through the guard
        // in startAdvertising(): that silently left the Mac not advertising at all.
        beginAdvertising(manager)
    }

    func start() {
        wantsAdvertising = true
        if let manager {
            if manager.state == .poweredOn { publishServiceAndAdvertise() }
            return
        }
        state = .starting
        // The first CBPeripheralManager creation triggers the Bluetooth permission prompt.
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func stop() {
        wantsAdvertising = false
        guard let manager else { return }
        if manager.isAdvertising { manager.stopAdvertising() }
        manager.removeAllServices()
        service = nil
        if manager.state == .poweredOn { state = .idle }
        Log.discovery.info("BLE advertising stopped")
    }

    private func publishServiceAndAdvertise() {
        guard let manager, wantsAdvertising else { return }
        if service != nil {
            startAdvertising()
            return
        }
        let characteristic = CBMutableCharacteristic(
            type: ProtocolConstants.endpointInfoCharacteristicUUID,
            properties: [.read],
            value: nil, // dynamic: served from peripheralManager(_:didReceiveRead:)
            permissions: [.readable]
        )
        let service = CBMutableService(type: ProtocolConstants.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        self.service = service
        manager.add(service)
    }

    private func startAdvertising() {
        guard let manager, wantsAdvertising, !manager.isAdvertising else { return }
        beginAdvertising(manager)
    }

    private func beginAdvertising(_ manager: CBPeripheralManager) {
        let wasPending = advertisedPending != nil
        advertisedName = nameProvider()
        advertisedPending = currentPending()
        // Two 128-bit UUIDs don't fit in an advertisement: the pending one replaces the service
        // UUID, and phones scan for both (protocol.md §2.8). The GATT service stays the same.
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: advertisedName,
            CBAdvertisementDataServiceUUIDsKey: [advertisedPending ?? ProtocolConstants.serviceUUID],
        ])
        if advertisedPending != nil && !wasPending { Log.discovery.info("Advertising pending delivery") }
    }

    /// The pending-delivery UUID to advertise now. One UUID fits at a time, so with files for
    /// several phones their UUIDs take turns; each phone notices its own within seconds.
    private func currentPending() -> CBUUID? {
        let pending = pendingProvider()
        if pending.count > 1 {
            if turnTimer == nil {
                turnTimer = Timer.scheduledTimer(withTimeInterval: Self.turnInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.pendingTurn += 1
                        self.refresh()
                    }
                }
            }
        } else {
            turnTimer?.invalidate()
            turnTimer = nil
            pendingTurn = 0
        }
        return pending.isEmpty ? nil : pending[pendingTurn % pending.count]
    }
}

extension BLEAdvertiser: @MainActor CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Log.discovery.info("Bluetooth state: \(peripheral.state.rawValue, privacy: .public)")
        switch peripheral.state {
        case .poweredOn:
            state = .starting
            publishServiceAndAdvertise()
        case .poweredOff:
            // CoreBluetooth drops published services when Bluetooth turns off; re-add on power on.
            service = nil
            state = .poweredOff
        case .unauthorized:
            service = nil
            state = .unauthorized
        case .unsupported:
            state = .unsupported
        case .resetting:
            service = nil
            state = .starting
        case .unknown:
            state = .starting
        @unknown default:
            state = .failed(reason: "Unknown Bluetooth state \(peripheral.state.rawValue)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            Log.discovery.error("Failed to add GATT service: \(error.localizedDescription, privacy: .public)")
            self.service = nil
            state = .failed(reason: error.localizedDescription)
            return
        }
        Log.discovery.info("GATT service published")
        startAdvertising()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            Log.discovery.error("Failed to start advertising: \(error.localizedDescription, privacy: .public)")
            state = .failed(reason: error.localizedDescription)
            return
        }
        // The private token is not secret, but logging it would make the Mac trackable from logs.
        let mode = advertisedName.hasPrefix(ProtocolConstants.pairingNamePrefix) ? "pairing mode (\(advertisedName))" : "private mode"
        Log.discovery.info("BLE advertising in \(mode, privacy: .public)")
        state = .advertising
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == ProtocolConstants.endpointInfoCharacteristicUUID else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }

        if request.offset == 0 || pendingReadValue == nil {
            guard let value = endpointValueProvider() else {
                Log.discovery.warning("Endpoint Info read while TCP listener is not ready")
                pendingReadValue = nil
                peripheral.respond(to: request, withResult: .unlikelyError)
                return
            }
            pendingReadValue = value
            Log.discovery.info("Endpoint Info read by central \(request.central.identifier.uuidString, privacy: .public)")
        }

        guard let value = pendingReadValue, request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        // CoreBluetooth truncates to the ATT MTU; the central continues with Read Blob requests.
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        peripheral.respond(to: first, withResult: .writeNotPermitted)
    }
}
