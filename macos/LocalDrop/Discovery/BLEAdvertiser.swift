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
    /// True while files wait for a phone: advertise the Pending Delivery UUID instead.
    private let pendingProvider: () -> Bool
    private var advertisedName = ""
    private var advertisedPending = false

    private var manager: CBPeripheralManager?
    private var service: CBMutableService?
    private var wantsAdvertising = false
    /// Snapshot served across a long (multi-request) GATT read so the bytes stay consistent.
    private var pendingReadValue: Data?

    init(nameProvider: @escaping () -> String, endpointValueProvider: @escaping () -> Data?, pendingProvider: @escaping () -> Bool) {
        self.nameProvider = nameProvider
        self.endpointValueProvider = endpointValueProvider
        self.pendingProvider = pendingProvider
        super.init()
    }

    /// Re-reads the name (token slot changed, pairing mode toggled) and the pending state, and
    /// re-advertises if either changed.
    func refresh() {
        guard let manager, wantsAdvertising, manager.state == .poweredOn, service != nil else { return }
        guard nameProvider() != advertisedName || pendingProvider() != advertisedPending else { return }
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
        advertisedName = nameProvider()
        advertisedPending = pendingProvider()
        // Two 128-bit UUIDs don't fit in an advertisement: the pending one replaces the service
        // UUID, and phones scan for both (protocol.md §2.8). The GATT service stays the same.
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: advertisedName,
            CBAdvertisementDataServiceUUIDsKey: [advertisedPending ? ProtocolConstants.pendingDeliveryUUID : ProtocolConstants.serviceUUID],
        ])
        if advertisedPending { Log.discovery.info("Advertising pending delivery") }
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
