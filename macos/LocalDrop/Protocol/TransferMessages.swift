import Foundation

/// One file announced in `transfer_request` (protocol/messages.md, FileInfo).
nonisolated struct TransferFileInfo: Equatable, Sendable {
    let fileId: Int
    /// Name as sent by the peer; sanitized before touching the file system.
    let name: String
    let mimeType: String
    let size: Int64
    /// Unix time in milliseconds.
    let lastModified: Int64?
}

nonisolated struct TransferRequest: Sendable {
    static let maxFiles = 1000

    let transferId: Data
    /// Grows with `transfer_add` while the request waits for a decision.
    private(set) var files: [TransferFileInfo]
    private(set) var totalSize: Int64

    init(_ message: Message) throws {
        try message.expect(MessageType.transferRequest)
        transferId = try message.bytes("transferId", count: 16)
        (files, totalSize) = try Self.parseFiles(message, after: [], previousTotal: 0, context: "transfer_request")
    }

    private init(transferId: Data, files: [TransferFileInfo], totalSize: Int64) {
        self.transferId = transferId
        self.files = files
        self.totalSize = totalSize
    }

    /// Adds the files of a `transfer_add` (protocol/messages.md).
    mutating func append(_ message: Message) throws {
        try message.expect(MessageType.transferAdd)
        guard try message.bytes("transferId", count: 16) == transferId else {
            throw SessionError.protocolViolation("transfer_add: unknown transferId")
        }
        (files, totalSize) = try Self.parseFiles(message, after: files, previousTotal: totalSize, context: "transfer_add")
    }

    /// The request as it was when it had its first [count] files.
    func prefix(_ count: Int) -> TransferRequest {
        let kept = Array(files.prefix(count))
        return TransferRequest(transferId: transferId, files: kept, totalSize: kept.reduce(0) { $0 + $1.size })
    }

    private static func parseFiles(
        _ message: Message,
        after existing: [TransferFileInfo],
        previousTotal: Int64,
        context: String
    ) throws -> ([TransferFileInfo], Int64) {
        guard let items = message.body["files"]?.array, !items.isEmpty, existing.count + items.count <= maxFiles else {
            throw SessionError.protocolViolation("\(context): a transfer has 1–\(maxFiles) files")
        }
        var files = existing
        var sum = previousTotal
        for item in items {
            guard case .map(let body) = item else { throw SessionError.protocolViolation("\(context): file is not a map") }
            let entry = Message(type: message.type, body: body)
            let fileId = try entry.uint("fileId")
            guard fileId == UInt64(files.count) else { throw SessionError.protocolViolation("\(context): fileId must continue the numbering") }
            let size = try entry.int64("size")
            let (newSum, overflow) = sum.addingReportingOverflow(size)
            guard !overflow else { throw SessionError.protocolViolation("\(context): total size overflows") }
            sum = newSum
            files.append(TransferFileInfo(
                fileId: files.count,
                name: try entry.text("name", maxBytes: 1024),
                mimeType: (try? entry.text("mimeType", maxBytes: 255)) ?? "application/octet-stream",
                size: size,
                lastModified: body["lastModified"]?.int64
            ))
        }
        guard try message.int64("totalSize") == sum else {
            throw SessionError.protocolViolation("\(context): totalSize does not match files")
        }
        return (files, sum)
    }
}

nonisolated struct FileBegin: Sendable {
    let transferId: Data
    let fileId: Int
    let offset: Int64

    init(_ message: Message) throws {
        try message.expect(MessageType.fileBegin)
        transferId = try message.bytes("transferId", count: 16)
        fileId = Int(clamping: try message.uint("fileId"))
        offset = try message.int64("offset")
    }
}

nonisolated struct FileChunk: Sendable {
    let transferId: Data
    let fileId: Int
    let offset: Int64
    let data: Data

    init(_ message: Message) throws {
        try message.expect(MessageType.fileChunk)
        transferId = try message.bytes("transferId", count: 16)
        fileId = Int(clamping: try message.uint("fileId"))
        offset = try message.int64("offset")
        data = try message.bytes("data")
        guard (1...ProtocolConstants.maxChunkSize).contains(data.count) else {
            throw SessionError.protocolViolation("file_chunk: data size \(data.count) out of range")
        }
    }
}

nonisolated struct FileEnd: Sendable {
    let transferId: Data
    let fileId: Int
    let sha256: Data

    init(_ message: Message) throws {
        try message.expect(MessageType.fileEnd)
        transferId = try message.bytes("transferId", count: 16)
        fileId = Int(clamping: try message.uint("fileId"))
        sha256 = try message.bytes("sha256", count: 32)
    }
}

nonisolated struct TextMessage: Sendable {
    let transferId: Data
    let text: String

    init(_ message: Message) throws {
        try message.expect(MessageType.text)
        transferId = try message.bytes("transferId", count: 16)
        text = try message.text("text", maxBytes: ProtocolConstants.maxTextSize)
        guard !text.isEmpty else { throw SessionError.protocolViolation("text: empty") }
    }
}

/// `transfer_reject.reason` values.
nonisolated enum RejectReason: String, Sendable {
    case declined
    case busy
    case insufficientStorage = "insufficient_storage"
    case timeout
    /// The receiver is asleep; the sender should keep the transfer and retry later.
    case asleep
}

nonisolated enum TransferMessages {
    /// [fileCount]: the first files the decision covers (more may have been added too late).
    static func accept(_ transferId: Data, fileCount: Int) -> Message {
        Message(type: MessageType.transferAccept, body: ["transferId": .bytes(transferId), "fileCount": .unsigned(UInt64(fileCount))])
    }

    static func reject(_ transferId: Data, reason: RejectReason, fileCount: Int? = nil) -> Message {
        var body: [String: CBORValue] = ["transferId": .bytes(transferId), "reason": .text(reason.rawValue)]
        if let fileCount { body["fileCount"] = .unsigned(UInt64(fileCount)) }
        return Message(type: MessageType.transferReject, body: body)
    }

    static func fileResult(_ transferId: Data, fileId: Int, ok: Bool, code: String? = nil) -> Message {
        var body: [String: CBORValue] = ["transferId": .bytes(transferId), "fileId": .unsigned(UInt64(fileId)), "ok": .bool(ok)]
        if let code { body["code"] = .text(code) }
        return Message(type: MessageType.fileResult, body: body)
    }

    static func transferResult(_ transferId: Data, completed: Bool, code: String? = nil) -> Message {
        var body: [String: CBORValue] = ["transferId": .bytes(transferId), "status": .text(completed ? "completed" : "failed")]
        if let code { body["code"] = .text(code) }
        return Message(type: MessageType.transferResult, body: body)
    }

    static func textResult(_ transferId: Data, copied: Bool) -> Message {
        Message(type: MessageType.textResult, body: ["transferId": .bytes(transferId), "status": .text(copied ? "copied" : "declined")])
    }

    static func cancel(_ transferId: Data, reason: String) -> Message {
        Message(type: MessageType.cancel, body: ["transferId": .bytes(transferId), "reason": .text(reason)])
    }
}
