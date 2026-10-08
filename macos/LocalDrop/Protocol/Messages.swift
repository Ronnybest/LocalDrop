import Foundation

/// Message type identifiers (`t` field), protocol/messages.md.
nonisolated enum MessageType {
    static let clientHello = "client_hello"
    static let serverHello = "server_hello"
    static let clientNonce = "client_nonce"
    static let serverAuth = "server_auth"
    static let clientAuth = "client_auth"
    static let sessionStatus = "session_status"
    static let pairingConfirm = "pairing_confirm"
    static let pairingResult = "pairing_result"
    static let transferRequest = "transfer_request"
    static let transferAdd = "transfer_add"
    static let transferAccept = "transfer_accept"
    static let transferReject = "transfer_reject"
    static let fileBegin = "file_begin"
    static let fileChunk = "file_chunk"
    static let fileEnd = "file_end"
    static let fileResult = "file_result"
    static let transferComplete = "transfer_complete"
    static let transferResult = "transfer_result"
    static let cancel = "cancel"
    static let text = "text"
    static let textResult = "text_result"
    static let close = "close"
    static let error = "error"
}

/// Error codes of the `error` message, protocol/messages.md.
nonisolated enum ErrorCode {
    static let versionUnsupported = "version_unsupported"
    static let badMessage = "bad_message"
    static let authFailed = "auth_failed"
    static let decryptFailed = "decrypt_failed"
    static let pairingRejected = "pairing_rejected"
    static let pairingTimeout = "pairing_timeout"
    static let notTrusted = "not_trusted"
    static let busy = "busy"
    static let pairingUnavailable = "pairing_unavailable"
    static let insufficientStorage = "insufficient_storage"
    static let writeFailed = "write_failed"
    static let checksumMismatch = "checksum_mismatch"
    static let sourceUnavailable = "source_unavailable"
    static let `internal` = "internal"
}

/// A decoded protocol message: its type plus the remaining fields.
nonisolated struct Message: Sendable {
    let type: String
    let body: [String: CBORValue]

    init(type: String, body: [String: CBORValue] = [:]) {
        self.type = type
        self.body = body
    }

    static func decode(_ payload: Data) throws -> Message {
        let value: CBORValue
        do {
            value = try CBOR.decode(payload)
        } catch {
            throw SessionError.protocolViolation(error.description)
        }
        guard case .map(var body) = value else { throw SessionError.protocolViolation("message is not a map") }
        guard let type = body.removeValue(forKey: "t")?.text else {
            throw SessionError.protocolViolation("message has no type")
        }
        return Message(type: type, body: body)
    }

    /// Decodes a plaintext handshake message; a peer `error` becomes `SessionError.peerError`.
    static func decodeHandshake(_ payload: Data) throws -> Message {
        let message = try decode(payload)
        if message.type == MessageType.error {
            let error = try ErrorMessage(message)
            throw SessionError.peerError(code: error.code, detail: error.detail)
        }
        return message
    }

    func encoded() -> Data {
        var map = body
        map["t"] = .text(type)
        return CBOR.encode(.map(map))
    }

    func expect(_ expected: String) throws {
        guard type == expected else {
            throw SessionError.protocolViolation("expected \(expected), got \(type)")
        }
    }

    func text(_ key: String, maxBytes: Int = 1024) throws -> String {
        guard let value = body[key]?.text else { throw SessionError.protocolViolation("\(type): missing text '\(key)'") }
        guard value.utf8.count <= maxBytes else { throw SessionError.protocolViolation("\(type): '\(key)' too long") }
        return value
    }

    func bytes(_ key: String, count: Int? = nil) throws -> Data {
        guard let value = body[key]?.bytes else { throw SessionError.protocolViolation("\(type): missing bytes '\(key)'") }
        if let count, value.count != count {
            throw SessionError.protocolViolation("\(type): '\(key)' must be \(count) bytes")
        }
        return value
    }

    func uint(_ key: String) throws -> UInt64 {
        guard let value = body[key]?.uint else { throw SessionError.protocolViolation("\(type): missing uint '\(key)'") }
        return value
    }

    /// An unsigned integer that must fit in Int64 (sizes, offsets).
    func int64(_ key: String) throws -> Int64 {
        let value = try uint(key)
        guard value <= UInt64(Int64.max) else { throw SessionError.protocolViolation("\(type): '\(key)' out of range") }
        return Int64(value)
    }

    func bool(_ key: String) throws -> Bool {
        guard let value = body[key]?.bool else { throw SessionError.protocolViolation("\(type): missing bool '\(key)'") }
        return value
    }
}

// MARK: - Handshake messages

nonisolated struct ClientHello: Sendable {
    static let maxNameBytes = 256

    let version: UInt64
    let minVersion: UInt64
    let deviceId: String
    let name: String
    let platform: String
    let identityKey: Data
    let ephemeralKey: Data
    let nonceCommit: Data
    let capabilities: [String]

    init(_ message: Message) throws {
        try message.expect(MessageType.clientHello)
        capabilities = message.body["caps"]?.array?.compactMap(\.text) ?? []
        version = try message.uint("v")
        minVersion = try message.uint("minV")
        deviceId = try message.text("id", maxBytes: 64)
        guard UUID(uuidString: deviceId) != nil else { throw SessionError.protocolViolation("client_hello: id is not a UUID") }
        name = try message.text("name", maxBytes: Self.maxNameBytes)
        platform = try message.text("platform", maxBytes: 32)
        identityKey = try message.bytes("idKey", count: 65)
        ephemeralKey = try message.bytes("eph", count: 65)
        nonceCommit = try message.bytes("nonceCommit", count: 32)
    }
}

nonisolated struct ServerHello: Sendable {
    let version: UInt64
    let deviceId: String
    let name: String
    let platform: String
    let identityKey: Data
    let ephemeralKey: Data
    let nonce: Data
    let capabilities: [String]

    var message: Message {
        Message(type: MessageType.serverHello, body: [
            "caps": .array(capabilities.map(CBORValue.text)),
            "v": .unsigned(version),
            "id": .text(deviceId),
            "name": .text(name),
            "platform": .text(platform),
            "idKey": .bytes(identityKey),
            "eph": .bytes(ephemeralKey),
            "nonce": .bytes(nonce),
        ])
    }
}

nonisolated struct ClientNonce: Sendable {
    let nonce: Data

    init(_ message: Message) throws {
        try message.expect(MessageType.clientNonce)
        nonce = try message.bytes("nonce", count: 32)
    }
}

nonisolated struct ClientAuth: Sendable {
    let signature: Data
    /// The client already trusts this Mac's identity key.
    let trusted: Bool
    /// The client knows this Mac's deviceId with a different key.
    let keyChanged: Bool

    init(_ message: Message) throws {
        try message.expect(MessageType.clientAuth)
        signature = try message.bytes("sig")
        trusted = try message.bool("trusted")
        keyChanged = try message.bool("keyChanged")
    }
}

nonisolated enum SessionStatus: String, Sendable {
    case trusted
    case pairingRequired = "pairing_required"
    case keyChanged = "key_changed"

    /// - Parameter presenceKey: sent only with `trusted` (messages.md, session_status).
    func message(presenceKey: Data?) -> Message {
        var body: [String: CBORValue] = ["status": .text(rawValue)]
        if self == .trusted, let presenceKey { body["presenceKey"] = .bytes(presenceKey) }
        return Message(type: MessageType.sessionStatus, body: body)
    }
}

nonisolated enum PairingMessages {
    static func confirmAccepted(_ message: Message) throws -> Bool {
        try message.expect(MessageType.pairingConfirm)
        return try message.bool("accepted")
    }

    static func result(accepted: Bool, presenceKey: Data? = nil) -> Message {
        var body: [String: CBORValue] = ["accepted": .bool(accepted)]
        if accepted, let presenceKey { body["presenceKey"] = .bytes(presenceKey) }
        return Message(type: MessageType.pairingResult, body: body)
    }
}

nonisolated struct ErrorMessage: Sendable {
    let code: String
    let detail: String?
    let supported: [UInt64]?

    init(code: String, detail: String? = nil, supported: [UInt64]? = nil) {
        self.code = code
        self.detail = detail
        self.supported = supported
    }

    init(_ message: Message) throws {
        try message.expect(MessageType.error)
        code = try message.text("code", maxBytes: 64)
        detail = message.body["message"]?.text
        supported = message.body["supported"]?.array?.compactMap(\.uint)
    }

    var message: Message {
        var body: [String: CBORValue] = ["code": .text(code)]
        if let detail { body["message"] = .text(detail) }
        if let supported { body["supported"] = .array(supported.map(CBORValue.unsigned)) }
        return Message(type: MessageType.error, body: body)
    }
}
