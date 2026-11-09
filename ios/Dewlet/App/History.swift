import Foundation

/// One line of Recent: something sent to or received from a Mac.
nonisolated struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case files, text, link
    }

    var id = UUID()
    var date = Date()
    var incoming: Bool
    var macName: String
    var kind: Kind
    /// The file name or "3 files"; for text and links the text itself, so a tap copies it again.
    var title: String
    var count = 1
    var bytes: Int64 = 0
    /// Received files still in Documents, by name: the app's container path changes with updates.
    var files: [String] = []
    /// Received photos and videos that went to the photo library instead.
    var savedToPhotos = 0
}

/// The last 100 entries, newest first, as JSON in Application Support.
nonisolated enum History {
    static let limit = 100
    private static let url = URL.applicationSupportDirectory.appending(path: "history.json")
    private static let queue = DispatchQueue(label: "com.zepponapps.localdrop.ios.history", qos: .utility)

    static func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try decoder.decode([HistoryEntry].self, from: data)
        } catch {
            Log.app.error("History unreadable, starting empty: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Written in order on a background queue: received texts can make the file large. Kept out
    /// of backups: clipboard text is often a password or a one-time code.
    static func save(_ entries: [HistoryEntry]) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(entries).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                // The atomic write replaced the file, and its flag with it.
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var written = url
                try written.setResourceValues(values)
            } catch {
                Log.app.error("Could not save history: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
