import Foundation

/// Minimal CBOR (RFC 8949) codec covering exactly the subset defined in protocol/protocol.md §4:
/// unsigned/negative integers, byte strings, text strings, arrays, maps with text keys,
/// `false`, `true`, `null`. Floats, tags and indefinite lengths are rejected.
nonisolated enum CBORValue: Equatable, Sendable {
    case unsigned(UInt64)
    /// Encodes the value `-1 - n`.
    case negative(UInt64)
    case bytes(Data)
    case text(String)
    case array([CBORValue])
    case map([String: CBORValue])
    case bool(Bool)
    case null

    static func int(_ value: Int64) -> CBORValue {
        value >= 0 ? .unsigned(UInt64(value)) : .negative(UInt64(-1 - value))
    }

    subscript(key: String) -> CBORValue? {
        if case .map(let entries) = self { return entries[key] }
        return nil
    }

    var uint: UInt64? {
        if case .unsigned(let value) = self { return value }
        return nil
    }

    var int64: Int64? {
        switch self {
        case .unsigned(let value): return value <= UInt64(Int64.max) ? Int64(value) : nil
        case .negative(let value): return value <= UInt64(Int64.max) ? -1 - Int64(value) : nil
        default: return nil
        }
    }

    var bytes: Data? {
        if case .bytes(let value) = self { return value }
        return nil
    }

    var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var array: [CBORValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

nonisolated enum CBORError: Error, Equatable, CustomStringConvertible {
    case truncated
    case unsupported(String)
    case invalidUTF8
    case nonTextMapKey
    case duplicateMapKey(String)
    case nestingTooDeep
    case lengthTooLarge
    case trailingBytes

    var description: String {
        switch self {
        case .truncated: return "CBOR: truncated input"
        case .unsupported(let what): return "CBOR: unsupported item (\(what))"
        case .invalidUTF8: return "CBOR: invalid UTF-8 in text string"
        case .nonTextMapKey: return "CBOR: map key is not a text string"
        case .duplicateMapKey(let key): return "CBOR: duplicate map key '\(key)'"
        case .nestingTooDeep: return "CBOR: nesting too deep"
        case .lengthTooLarge: return "CBOR: declared length exceeds input"
        case .trailingBytes: return "CBOR: trailing bytes after top-level item"
        }
    }
}

nonisolated enum CBOR {
    static let maxDepth = 16

    // MARK: Encoding

    static func encode(_ value: CBORValue) -> Data {
        var out = Data()
        encode(value, into: &out)
        return out
    }

    private static func encode(_ value: CBORValue, into out: inout Data) {
        switch value {
        case .unsigned(let n):
            writeHead(major: 0, argument: n, into: &out)
        case .negative(let n):
            writeHead(major: 1, argument: n, into: &out)
        case .bytes(let data):
            writeHead(major: 2, argument: UInt64(data.count), into: &out)
            out.append(data)
        case .text(let string):
            let utf8 = Data(string.utf8)
            writeHead(major: 3, argument: UInt64(utf8.count), into: &out)
            out.append(utf8)
        case .array(let items):
            writeHead(major: 4, argument: UInt64(items.count), into: &out)
            for item in items { encode(item, into: &out) }
        case .map(let entries):
            writeHead(major: 5, argument: UInt64(entries.count), into: &out)
            // Deterministic order (RFC 8949 §4.2.1): shorter encoded key first, then bytewise.
            let sortedKeys = entries.keys.sorted { lhs, rhs in
                let l = Array(lhs.utf8), r = Array(rhs.utf8)
                return l.count != r.count ? l.count < r.count : l.lexicographicallyPrecedes(r)
            }
            for key in sortedKeys {
                encode(.text(key), into: &out)
                encode(entries[key]!, into: &out)
            }
        case .bool(let flag):
            out.append(flag ? 0xF5 : 0xF4)
        case .null:
            out.append(0xF6)
        }
    }

    private static func writeHead(major: UInt8, argument: UInt64, into out: inout Data) {
        let prefix = major << 5
        switch argument {
        case 0..<24:
            out.append(prefix | UInt8(argument))
        case 24...UInt64(UInt8.max):
            out.append(prefix | 24)
            out.append(UInt8(argument))
        case (UInt64(UInt8.max) + 1)...UInt64(UInt16.max):
            out.append(prefix | 25)
            appendBigEndian(UInt16(argument), into: &out)
        case (UInt64(UInt16.max) + 1)...UInt64(UInt32.max):
            out.append(prefix | 26)
            appendBigEndian(UInt32(argument), into: &out)
        default:
            out.append(prefix | 27)
            appendBigEndian(argument, into: &out)
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, into out: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
    }

    // MARK: Decoding

    static func decode(_ data: Data) throws(CBORError) -> CBORValue {
        var reader = Reader(bytes: [UInt8](data))
        let value = try reader.readItem(depth: 0)
        guard reader.isAtEnd else { throw .trailingBytes }
        return value
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0

        var isAtEnd: Bool { position == bytes.count }
        var remaining: Int { bytes.count - position }

        mutating func readByte() throws(CBORError) -> UInt8 {
            guard position < bytes.count else { throw .truncated }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func readUInt(byteCount: Int) throws(CBORError) -> UInt64 {
            guard remaining >= byteCount else { throw .truncated }
            var value: UInt64 = 0
            for _ in 0..<byteCount {
                value = (value << 8) | UInt64(bytes[position])
                position += 1
            }
            return value
        }

        mutating func readArgument(additional: UInt8) throws(CBORError) -> UInt64 {
            switch additional {
            case 0..<24: return UInt64(additional)
            case 24: return try readUInt(byteCount: 1)
            case 25: return try readUInt(byteCount: 2)
            case 26: return try readUInt(byteCount: 4)
            case 27: return try readUInt(byteCount: 8)
            case 31: throw .unsupported("indefinite length")
            default: throw .unsupported("reserved additional info \(additional)")
            }
        }

        mutating func readLength(additional: UInt8) throws(CBORError) -> Int {
            let length = try readArgument(additional: additional)
            // Every item occupies at least one byte, so a count larger than the input is invalid.
            guard length <= UInt64(remaining) else { throw .lengthTooLarge }
            return Int(length)
        }

        mutating func readItem(depth: Int) throws(CBORError) -> CBORValue {
            guard depth <= CBOR.maxDepth else { throw .nestingTooDeep }
            let initial = try readByte()
            let major = initial >> 5
            let additional = initial & 0x1F

            switch major {
            case 0:
                return .unsigned(try readArgument(additional: additional))
            case 1:
                return .negative(try readArgument(additional: additional))
            case 2:
                let length = try readLength(additional: additional)
                defer { position += length }
                return .bytes(Data(bytes[position..<(position + length)]))
            case 3:
                let length = try readLength(additional: additional)
                guard let string = String(bytes: bytes[position..<(position + length)], encoding: .utf8) else {
                    throw .invalidUTF8
                }
                position += length
                return .text(string)
            case 4:
                let count = try readLength(additional: additional)
                var items: [CBORValue] = []
                items.reserveCapacity(count)
                for _ in 0..<count { items.append(try readItem(depth: depth + 1)) }
                return .array(items)
            case 5:
                let count = try readLength(additional: additional)
                var entries: [String: CBORValue] = [:]
                entries.reserveCapacity(count)
                for _ in 0..<count {
                    guard case .text(let key) = try readItem(depth: depth + 1) else { throw .nonTextMapKey }
                    guard entries[key] == nil else { throw .duplicateMapKey(key) }
                    entries[key] = try readItem(depth: depth + 1)
                }
                return .map(entries)
            case 6:
                throw .unsupported("tag")
            default:
                switch additional {
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22: return .null
                case 25, 26, 27: throw .unsupported("float")
                default: throw .unsupported("simple value \(additional)")
                }
            }
        }
    }
}
