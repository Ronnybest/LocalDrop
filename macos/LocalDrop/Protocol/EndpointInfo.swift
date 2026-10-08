import Foundation

/// Value of the Endpoint Info GATT characteristic (protocol/protocol.md §2.3).
nonisolated struct EndpointInfo: Equatable, Sendable {
    var protocolVersion: UInt64
    var deviceId: String
    var deviceName: String
    var platform: String
    var port: UInt16
    var addresses: [String]
    var fingerprint: Data
    var busy: Bool
    var capabilities: [String]

    /// The open form, served in pairing mode and sealed in private mode.
    func encoded() -> Data {
        CBOR.encode(.map([
            "v": .unsigned(protocolVersion),
            "id": .text(deviceId),
            "name": .text(deviceName),
            "platform": .text(platform),
            "port": .unsigned(UInt64(port)),
            "addrs": .array(addresses.map(CBORValue.text)),
            "fp": .bytes(fingerprint),
            "busy": .bool(busy),
            "caps": .array(capabilities.map(CBORValue.text)),
        ]))
    }

    /// Private mode: readable only by devices holding the presence key (protocol.md §2.3).
    func sealed(with key: PresenceKey) throws -> Data {
        CBOR.encode(.map([
            "v": .unsigned(protocolVersion),
            "sealed": .bytes(try key.sealEndpoint(encoded())),
        ]))
    }
}
