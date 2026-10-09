import Foundation
import os

/// Folders being packed for a phone: shown in the menu and on the menu bar icon, since packing a
/// large folder takes a moment before the files can go.
@Observable
final class FolderPacking: Identifiable {
    let id = UUID()
    let deviceId: String
    /// The folder's name, or how many folders.
    let title: String
    /// Share of the archive written; nil while the files are being gathered.
    var fraction: Double?
    @ObservationIgnored let cancelToken = TransferCancelToken()

    init(deviceId: String, folders: [URL]) {
        self.deviceId = deviceId
        title = folders.count == 1 ? folders[0].lastPathComponent : String(localized: "\(folders.count) folders")
    }
}

/// A folder as a zip archive for the phone, which saves it as one file.
nonisolated enum FolderArchive {
    struct Packed {
        let archive: URL
        /// Files macOS doesn't let LocalDrop read, left out.
        let skipped: [String]
    }

    enum PackError: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: "cancelled"
            case .failed(let reason): reason
            }
        }
    }

    /// Packs [folder] into [directory].
    ///
    /// The readable files are first cloned into a copy (instant on APFS): a file another app
    /// labelled as its own (`com.apple.macl`) can't be read by LocalDrop, keeps that label when
    /// cloned, and would make the whole folder fail. The copy is then archived by `ditto`, as
    /// Finder's Compress does, but without compression: it runs at disk speed, many times faster
    /// than the network, where compressing ran at a tenth of it and most large files (photos,
    /// videos, archives) are compressed already. Its size gives the progress.
    static func pack(_ folder: URL, into directory: URL, cancel: TransferCancelToken,
                     progress: @escaping @Sendable (Double) -> Void) throws -> Packed {
        let fileManager = FileManager.default
        let copyRoot = directory.appendingPathComponent("Copy-\(UUID().uuidString)", isDirectory: true)
        let copy = copyRoot.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        try fileManager.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: copyRoot) }

        var skipped: [String] = []
        var totalBytes: Int64 = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let base = folder.standardizedFileURL.pathComponents.count
        let items = fileManager.enumerator(at: folder, includingPropertiesForKeys: keys, options: [], errorHandler: { url, _ in
            skipped.append(url.lastPathComponent)
            return true
        })
        while let item = items?.nextObject() as? URL {
            if cancel.isCancelled { throw PackError.cancelled }
            // Finder's own view settings, not content.
            if item.lastPathComponent == ".DS_Store" { continue }
            let relative = item.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/")
            let target = copy.appendingPathComponent(relative)
            let values = try? item.resourceValues(forKeys: Set(keys))
            do {
                if values?.isDirectory == true {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                    continue
                }
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: item, to: target)
                guard isReadable(target) else {
                    try? fileManager.removeItem(at: target)
                    skipped.append(relative)
                    continue
                }
                totalBytes += Int64(values?.fileSize ?? 0)
            } catch {
                skipped.append(relative)
            }
        }

        let archive = uniqueURL(directory.appendingPathComponent(folder.lastPathComponent + ".zip"))
        try runDitto(copy, to: archive, totalBytes: totalBytes, cancel: cancel, progress: progress)
        return Packed(archive: archive, skipped: skipped)
    }

    /// Whether this process may read the file: the sandbox decides on open, not on copy.
    private static func isReadable(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    private static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = url.deletingPathExtension().lastPathComponent
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(name) \(number).zip")
            number += 1
        }
        return candidate
    }

    private static func runDitto(_ source: URL, to archive: URL, totalBytes: Int64, cancel: TransferCancelToken,
                                 progress: @escaping @Sendable (Double) -> Void) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // A PKZip archive with the folder itself at its root; no resource forks, extended
        // attributes or __MACOSX entries, which mean nothing on the phone.
        process.arguments = ["-c", "-k", "--norsrc", "--noqtn", "--keepParent", "--zlibCompressionLevel", "0",
                             source.path, archive.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()

        var reported = -1
        while process.isRunning {
            if cancel.isCancelled { process.terminate() }
            Thread.sleep(forTimeInterval: 0.1)
            guard totalBytes > 0 else { continue }
            // Not URL resource values: those are cached on the URL, which then reports a size
            // from before the archive was finished.
            let written = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
            let percent = min(100, Int(Double(written) / Double(totalBytes) * 100))
            if percent != reported {
                reported = percent
                progress(Double(percent) / 100)
            }
        }
        process.waitUntilExit()
        if cancel.isCancelled {
            try? FileManager.default.removeItem(at: archive)
            throw PackError.cancelled
        }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            Log.transfer.warning("ditto: \(message, privacy: .public)")
        }
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: archive)
            throw PackError.failed(message.isEmpty ? "ditto exited with \(process.terminationStatus)" : message)
        }
        progress(1)
    }
}
