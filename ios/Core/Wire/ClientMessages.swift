import CryptoKit
import Foundation

// The Initiator's half of the handshake messages (protocol/messages.md). The Mac's
// Messages.swift has the other half: it parses what is built here and builds what is parsed here.

nonisolated extension ClientHello {
    init(deviceId: String, name: String, identityKey: Data, ephemeralKey: Data, nonceCommit: Data) {
        version = ProtocolConstants.version
        minVersion = ProtocolConstants.minSupportedVersion
        self.deviceId = deviceId
        self.name = name
        platform = ProtocolConstants.platform
        self.identityKey = identityKey
        self.ephemeralKey = ephemeralKey
        self.nonceCommit = nonceCommit
        capabilities = ProtocolConstants.capabilities
    }

    var message: Message {
        Message(type: MessageType.clientHello, body: [
            "v": .unsigned(version),
            "minV": .unsigned(minVersion),
            "id": .text(deviceId),
            "name": .text(name),
            "platform": .text(platform),
            "idKey": .bytes(identityKey),
            "eph": .bytes(ephemeralKey),
            "nonceCommit": .bytes(nonceCommit),
            "caps": .array(capabilities.map(CBORValue.text)),
        ])
    }

    /// What `client_hello.name` allows: no control characters, at most 64 characters (what the Mac
    /// shows) and 256 UTF-8 bytes (what it accepts).
    static func wireName(_ raw: String) -> String {
        var name = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        name = String(name.prefix(64))
        while name.utf8.count > maxNameBytes { name.removeLast() }
        return name.isEmpty ? "iPhone" : name
    }
}

nonisolated extension ServerHello {
    init(_ message: Message) throws {
        try message.expect(MessageType.serverHello)
        version = try message.uint("v")
        deviceId = try message.text("id", maxBytes: 64)
        name = try message.text("name")
        platform = try message.text("platform", maxBytes: 32)
        identityKey = try message.bytes("idKey", count: 65)
        ephemeralKey = try message.bytes("eph", count: 65)
        nonce = try message.bytes("nonce", count: 32)
        capabilities = message.body["caps"]?.array?.compactMap(\.text) ?? []
    }
}

nonisolated extension ClientNonce {
    static func message(_ nonce: Data) -> Message {
        Message(type: MessageType.clientNonce, body: ["nonce": .bytes(nonce)])
    }
}

nonisolated extension ClientAuth {
    /// All three fields are required: the Mac answers `bad_message` without `trusted` or `keyChanged`.
    static func message(signature: Data, trusted: Bool, keyChanged: Bool) -> Message {
        Message(type: MessageType.clientAuth, body: ["sig": .bytes(signature), "trusted": .bool(trusted), "keyChanged": .bool(keyChanged)])
    }
}

nonisolated extension SessionStatus {
    /// The status and, with `trusted`, the Mac's presence key (only a 32-byte one counts, as on Android).
    static func parse(_ message: Message) throws -> (status: SessionStatus, presenceKey: Data?) {
        try message.expect(MessageType.sessionStatus)
        guard let status = SessionStatus(rawValue: try message.text("status", maxBytes: 64)) else {
            throw SessionError.protocolViolation("session_status: unknown status")
        }
        return (status, status == .trusted ? message.body["presenceKey"]?.bytes.flatMap { $0.count == PresenceKey.size ? $0 : nil } : nil)
    }
}

nonisolated extension PairingMessages {
    static func confirm(accepted: Bool) -> Message {
        Message(type: MessageType.pairingConfirm, body: ["accepted": .bool(accepted)])
    }

    static func parseResult(_ message: Message) throws -> (accepted: Bool, presenceKey: Data?) {
        try message.expect(MessageType.pairingResult)
        let accepted = try message.bool("accepted")
        return (accepted, accepted ? message.body["presenceKey"]?.bytes.flatMap { $0.count == PresenceKey.size ? $0 : nil } : nil)
    }
}

nonisolated extension PresenceKey {
    /// Opens a sealed Endpoint Info (`nonce ‖ ciphertext ‖ tag`, protocol.md §2.3).
    func openEndpoint(_ sealed: Data) throws -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw), salt: Data(),
                                         info: Data("localdrop/v1/endpoint".utf8), outputByteCount: 32)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }
}

nonisolated extension EndpointInfo {
    /// The GATT characteristic's value, open or sealed (Android `EndpointInfo.decode`). For the
    /// Bluetooth path; `busy` and `caps` are optional, unknown keys ignored.
    init(decoding data: Data, presenceKey: PresenceKey?) throws {
        var value = try CBOR.decode(data)
        if let sealed = value["sealed"]?.bytes {
            guard let presenceKey else { throw SessionError.protocolViolation("sealed Endpoint Info without a presence key") }
            value = try CBOR.decode(try presenceKey.openEndpoint(sealed))
        }
        guard case .map(let body) = value else { throw SessionError.protocolViolation("Endpoint Info is not a map") }
        let info = Message(type: "endpoint", body: body)
        let port = try info.uint("port")
        guard (1...65535).contains(port) else { throw SessionError.protocolViolation("Endpoint Info: port out of range") }
        guard let addresses = body["addrs"]?.array else { throw SessionError.protocolViolation("Endpoint Info: missing addrs") }
        self.init(
            protocolVersion: try info.uint("v"),
            deviceId: try info.text("id", maxBytes: 64),
            deviceName: try info.text("name"),
            platform: try info.text("platform", maxBytes: 32),
            port: UInt16(port),
            addresses: try addresses.map { item in
                guard let text = item.text else { throw SessionError.protocolViolation("Endpoint Info: address is not text") }
                return text
            },
            fingerprint: try info.bytes("fp", count: 32),
            busy: body["busy"]?.bool ?? false,
            capabilities: body["caps"]?.array?.compactMap(\.text) ?? []
        )
    }
}
