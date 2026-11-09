import Foundation
import Testing
@testable import LocalDrop

struct MacStoreTests {
    private let directory = URL.temporaryDirectory.appending(path: "MacStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    private var file: URL { directory.appending(path: "Dewlet/paired-macs.json") }

    static func mac(_ id: String = UUID().uuidString.lowercased(), key: UInt8 = 4, presenceKey: Data? = nil) -> PairedMac {
        let publicKey = Data(repeating: key, count: 65)
        return PairedMac(id: id, name: "MacBook", publicKey: publicKey, fingerprint: Data(repeating: key, count: 32), presenceKey: presenceKey,
                         capabilities: ["send"], lastAddresses: [], lastPort: nil, firstSeen: Date(timeIntervalSince1970: 1000),
                         lastSeen: Date(timeIntervalSince1970: 1000), receiveAutomatically: false)
    }

    @Test func pairingAgainWithTheSameKeyKeepsHistoryAndSettings() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MacStore(fileURL: file)
        let original = Self.mac(presenceKey: Data(repeating: 1, count: 32))
        try store.trust(original)
        try store.noteSession(id: original.id, name: "Studio", capabilities: ["send", "clipboardReceive"], presenceKey: nil, addresses: ["10.0.0.2"], port: 51010)
        try store.setReceiveAutomatically(true, id: original.id)

        var again = Self.mac(original.id)
        again.firstSeen = Date()
        try store.trust(again)
        let kept = try #require(store.mac(original.id))
        #expect(kept.firstSeen == original.firstSeen)
        #expect(kept.receiveAutomatically)
        #expect(kept.lastAddresses == ["10.0.0.2"] && kept.lastPort == 51010)
        #expect(kept.presenceKey == Data(repeating: 1, count: 32))

        // A new key starts over.
        try store.trust(Self.mac(original.id, key: 5))
        let fresh = try #require(store.mac(original.id))
        #expect(!fresh.receiveAutomatically && fresh.lastAddresses.isEmpty && fresh.presenceKey == nil)
        #expect(store.macs.count == 1)
    }

    @Test func sessionFactsArePersisted() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MacStore(fileURL: file)
        let mac = Self.mac()
        try store.trust(mac)
        try store.noteSession(id: mac.id, name: "Mac mini", capabilities: ["send"], presenceKey: Data(repeating: 2, count: 32), addresses: ["127.0.0.1", "::1"], port: 1)
        try store.noteSession(id: mac.id, name: "Mac mini", capabilities: ["send"], presenceKey: nil, addresses: [], port: 0)

        let reloaded = MacStore(fileURL: file)
        let stored = try #require(reloaded.mac(mac.id))
        #expect(stored.name == "Mac mini")
        #expect(stored.presenceKey == Data(repeating: 2, count: 32))
        #expect(stored.lastAddresses == ["127.0.0.1", "::1"] && stored.lastPort == 1)
        #expect(stored.lastSeen > mac.lastSeen)
        #expect(try file.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        try reloaded.forget(mac.id)
        #expect(MacStore(fileURL: file).macs.isEmpty)
    }

    @Test func newestFirstAndChangesAreStreamed() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MacStore(fileURL: file)
        var changes = store.changes().makeAsyncIterator()
        #expect(await changes.next() == [])
        let older = Self.mac()
        var newer = Self.mac()
        newer.lastSeen = Date(timeIntervalSince1970: 2000)
        try store.trust(older)
        #expect(await changes.next()?.map(\.id) == [older.id])
        try store.trust(newer)
        #expect(await changes.next()?.map(\.id) == [newer.id, older.id])
    }

    @Test func aCorruptFileIsMovedAside() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let store = MacStore(fileURL: file)
        #expect(store.macs.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(names.contains { $0.hasPrefix("paired-macs.json.corrupt-") })
        try store.trust(Self.mac())
        #expect(MacStore(fileURL: file).macs.count == 1)
    }
}
