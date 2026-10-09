import CryptoKit
import Foundation
import Security

/// Long-term device identity: an ECDSA P-256 key pair whose private part lives only in the Keychain.
nonisolated struct Identity: Sendable {
    let privateKey: P256.Signing.PrivateKey

    var publicKeyX963: Data { privateKey.publicKey.x963Representation }

    /// SHA-256 of the X9.63 public key (protocol/security.md §2).
    var fingerprint: Data { Data(SHA256.hash(data: publicKeyX963)) }
}

nonisolated enum IdentityStoreError: Error, CustomStringConvertible {
    case keychain(operation: String, status: OSStatus)
    case corruptKey(underlying: Error)

    var description: String {
        switch self {
        case .keychain(let operation, let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain \(operation) failed: \(status) (\(message))"
        case .corruptKey(let underlying):
            return "Stored identity key is unreadable: \(underlying)"
        }
    }
}

/// Loads or creates the identity key in the Keychain.
nonisolated enum IdentityStore {
    private static let item = KeychainBlob(service: "dev.localdrop.identity", account: "identity-p256-v1", label: "LocalDrop device identity")

    static func loadOrCreate() throws(IdentityStoreError) -> Identity {
        if let raw = try item.read() {
            do {
                return Identity(privateKey: try P256.Signing.PrivateKey(rawRepresentation: raw))
            } catch {
                throw .corruptKey(underlying: error)
            }
        }
        let key = P256.Signing.PrivateKey()
        let usedDataProtection = try item.add(key.rawRepresentation)
        Log.crypto.info("Generated new identity key (dataProtectionKeychain=\(usedDataProtection, privacy: .public))")
        return Identity(privateKey: key)
    }
}

/// One secret blob stored as a generic password item.
///
/// The data-protection keychain is preferred. It requires a signing team (keychain-access-groups);
/// ad-hoc "Sign to Run Locally" builds don't have one, so the file-based login keychain is used
/// as a fallback. Lookup checks both so an existing item is never silently replaced.
nonisolated struct KeychainBlob: Sendable {
    let service: String
    let account: String
    let label: String

    private enum ReadResult {
        case found(Data)
        case notFound
        case missingEntitlement
        case failed(OSStatus)
    }

    /// The stored value, or nil if there is none in either keychain.
    func read() throws(IdentityStoreError) -> Data? {
        switch read(dataProtection: true) {
        case .found(let raw): return raw
        case .notFound, .missingEntitlement: break
        case .failed(let status): throw .keychain(operation: "read", status: status)
        }
        switch read(dataProtection: false) {
        case .found(let raw): return raw
        case .notFound, .missingEntitlement: return nil
        case .failed(let status): throw .keychain(operation: "read", status: status)
        }
    }

    /// Adds the value; returns whether it went to the data-protection keychain.
    @discardableResult
    func add(_ raw: Data) throws(IdentityStoreError) -> Bool {
        // Ad-hoc signed builds can query the data-protection keychain but not add to it.
        let status = add(raw, dataProtection: true)
        if status == errSecSuccess { return true }
        guard status == errSecMissingEntitlement else { throw .keychain(operation: "add", status: status) }
        let legacyStatus = add(raw, dataProtection: false)
        guard legacyStatus == errSecSuccess else { throw .keychain(operation: "add", status: legacyStatus) }
        return false
    }

    /// Replaces the value wherever it is stored.
    func replace(with raw: Data) throws(IdentityStoreError) {
        for dataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
                throw .keychain(operation: "delete", status: status)
            }
        }
        try add(raw)
    }

    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func read(dataProtection: Bool) -> ReadResult {
        var query = baseQuery(dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed(errSecInternalError) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        case errSecMissingEntitlement:
            return .missingEntitlement
        default:
            return .failed(status)
        }
    }

    private func add(_ raw: Data, dataProtection: Bool) -> OSStatus {
        var query = baseQuery(dataProtection: dataProtection)
        query[kSecValueData as String] = raw
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false
        query[kSecAttrLabel as String] = label
        return SecItemAdd(query as CFDictionary, nil)
    }
}

/// The code both devices of a pair show, for the user to compare at any time after pairing
/// (security.md §2): from both identity keys in a fixed order, 12 digits in groups of 4. Unlike
/// the SAS, it stays the same until either key changes.
nonisolated enum PairVerification {
    static func code(_ publicKeyA: Data, _ publicKeyB: Data) -> String {
        let (low, high) = publicKeyA.lexicographicallyPrecedes(publicKeyB) ? (publicKeyA, publicKeyB) : (publicKeyB, publicKeyA)
        let hash = Data(SHA256.hash(data: Data("localdrop/v1/verify".utf8) + low + high))
        let value = hash.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let digits = String(format: "%012llu", value % 1_000_000_000_000)
        return stride(from: 0, to: 12, by: 4).map { offset in
            let start = digits.index(digits.startIndex, offsetBy: offset)
            return String(digits[start..<digits.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }
}

extension Data {
    /// Human-readable fingerprint: first 16 bytes as uppercase hex in groups of 4.
    nonisolated var fingerprintDisplay: String {
        let hex = prefix(16).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }

    /// Short prefix safe for logs.
    nonisolated var fingerprintLogPrefix: String {
        prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
