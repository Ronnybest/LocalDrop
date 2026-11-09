import Foundation

/// A `transfer_request` from the Mac (Android `IncomingRequest`). Not the Mac's `TransferRequest`
/// parser: that one stops at 1000 files, and the Mac sends a delivery of any size in one request
/// — refusing it would leave the delivery interrupted and offered again on every poll.
nonisolated struct IncomingRequest: Sendable {
    let transferId: Data
    /// Names already safe as file names on this iPhone.
    let files: [TransferFileInfo]
    let totalSize: Int64

    init(_ message: Message) throws {
        try message.expect(MessageType.transferRequest)
        transferId = try message.bytes("transferId", count: 16)
        guard let items = message.body["files"]?.array, !items.isEmpty else {
            throw SessionError.protocolViolation("transfer_request: no files")
        }
        var files: [TransferFileInfo] = []
        var sum: Int64 = 0
        for item in items {
            guard case .map(let body) = item else { throw SessionError.protocolViolation("transfer_request: file is not a map") }
            let entry = Message(type: message.type, body: body)
            guard try entry.uint("fileId") == UInt64(files.count) else {
                throw SessionError.protocolViolation("transfer_request: fileId must equal its index")
            }
            let size = try entry.int64("size")
            let (newSum, overflow) = sum.addingReportingOverflow(size)
            guard !overflow else { throw SessionError.protocolViolation("transfer_request: total size overflows") }
            sum = newSum
            let mimeType = body["mimeType"]?.text ?? ""
            files.append(TransferFileInfo(
                fileId: files.count,
                name: Self.sanitize(try entry.text("name")),
                mimeType: mimeType.isEmpty ? "application/octet-stream" : mimeType,
                size: size,
                lastModified: body["lastModified"]?.int64
            ))
        }
        guard try message.int64("totalSize") == sum else {
            throw SessionError.protocolViolation("transfer_request: totalSize does not match files")
        }
        self.files = files
        totalSize = sum
    }

    /// Names from another device never become paths (Android `FileNames.sanitize`): the part after
    /// the last separator, no control or format characters (the shared `FileNames` drops the same
    /// ones when saving, so the Accept prompt shows the name that is saved; a bidi override would
    /// show another), `:*?"<>|` replaced, no leading dots, at most 200 characters with the extension kept.
    static func sanitize(_ raw: String) -> String {
        let last = raw.split(omittingEmptySubsequences: false) { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? raw
        let forbidden = Set(":*?\"<>|".unicodeScalars)
        let dropped = CharacterSet.controlCharacters.union(.illegalCharacters)
        let scalars = last.unicodeScalars
            .filter { !dropped.contains($0) }
            .map { forbidden.contains($0) ? "_" : $0 }
        var name = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { return "file" }
        guard name.count > 200 else { return name }
        let ext = String((name as NSString).pathExtension.prefix(16))
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        return ext.isEmpty ? String(base.prefix(200)) : "\(base.prefix(200 - ext.count - 1)).\(ext)"
    }
}
