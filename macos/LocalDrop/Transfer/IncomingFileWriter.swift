import CryptoKit
import Foundation

/// Writes one incoming file to a hidden temporary file next to its destination, hashing as it
/// goes. The file appears under its real name only after the SHA-256 matches; otherwise the
/// temporary file is deleted.
nonisolated final class IncomingFileWriter {
    static let temporaryPrefix = ".localdrop-"
    static let temporarySuffix = ".partial"

    let info: TransferFileInfo
    /// Recorded as the file's origin ("Where from" in Finder's Get Info).
    private let origin: String
    private let directory: URL
    private let temporaryURL: URL
    private let handle: FileHandle
    private var hasher = SHA256()
    private(set) var bytesWritten: Int64 = 0
    private var finished = false

    init(directory: URL, info: TransferFileInfo, origin: String) throws {
        self.info = info
        self.origin = origin
        self.directory = directory
        temporaryURL = directory.appendingPathComponent("\(Self.temporaryPrefix)\(UUID().uuidString)\(Self.temporarySuffix)")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw SessionError.writeFailed("cannot create a file in \(directory.path)")
        }
        do {
            handle = try FileHandle(forWritingTo: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw Self.mapWriteError(error)
        }
    }

    func write(_ data: Data) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw Self.mapWriteError(error)
        }
        hasher.update(data: data)
        bytesWritten += Int64(data.count)
    }

    /// Verifies the hash and moves the file to a unique name in the destination directory.
    func finish(expectedSHA256: Data) throws -> URL {
        finished = true
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw Self.mapWriteError(error)
        }
        let actual = Data(hasher.finalize())
        guard actual == expectedSHA256 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw SessionError.checksumMismatch(fileName: info.name)
        }
        if let lastModified = info.lastModified {
            let date = Date(timeIntervalSince1970: TimeInterval(lastModified) / 1000)
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: temporaryURL.path)
        }
        setWhereFrom(temporaryURL)
        do {
            return try FileNames.moveToUniqueName(temporaryURL, directory: directory, name: FileNames.sanitize(info.name))
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw Self.mapWriteError(error)
        }
    }

    /// Sets `kMDItemWhereFroms`, which Finder shows as "Where from". Best effort: metadata only.
    private func setWhereFrom(_ url: URL) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: [origin], format: .binary, options: 0) else { return }
        let result = data.withUnsafeBytes { bytes in
            setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", bytes.baseAddress, bytes.count, 0, 0)
        }
        if result != 0 {
            Log.transfer.info("Could not set Where-from metadata: errno \(errno)")
        }
    }

    /// Deletes the partial file. Safe to call more than once.
    func discard() {
        guard !finished else { return }
        finished = true
        try? handle.close()
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    /// Removes partial files left by a crash. Called at launch, when no transfer can be running.
    static func removeLeftovers(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(temporaryPrefix) && name.hasSuffix(temporarySuffix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            Log.transfer.info("Removed leftover partial file \(name, privacy: .public)")
        }
    }

    private static func mapWriteError(_ error: Error) -> SessionError {
        if let sessionError = error as? SessionError { return sessionError }
        let nsError = error as NSError
        let outOfSpace = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC))
            || ((nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map { $0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC) } ?? false)
        return outOfSpace ? .insufficientStorage : .writeFailed(nsError.localizedDescription)
    }
}

nonisolated enum FileNames {
    private static let maxNameBytes = 255

    /// Makes a peer-supplied name safe as a single path component (protocol/security.md §8).
    static func sanitize(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.illegalCharacters)
        var name = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !forbidden.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        while name.utf8.count > maxNameBytes {
            // Shorten the base name, keeping the extension.
            let ext = (name as NSString).pathExtension
            var base = (name as NSString).deletingPathExtension
            guard !base.isEmpty else { name = String(name.prefix(100)); break }
            base.removeLast()
            name = ext.isEmpty ? base : "\(base).\(ext)"
        }
        return name.isEmpty ? "file" : name
    }

    /// Moves `source` into `directory` as `name`, or `name (n)` if taken. Never overwrites.
    static func moveToUniqueName(_ source: URL, directory: URL, name: String) throws -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for attempt in 0..<10_000 {
            let candidate = attempt == 0 ? name : (ext.isEmpty ? "\(base) (\(attempt))" : "\(base) (\(attempt)).\(ext)")
            let destination = directory.appendingPathComponent(candidate)
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                continue
            }
        }
        throw SessionError.writeFailed("no free file name for \(name)")
    }
}
