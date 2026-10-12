import Foundation
import Testing
@testable import LocalDrop

/// The presence key given to each device (see PresenceKey.rotate): older records read without
/// it, and what is noted survives a restart.
@MainActor
struct TrustedDeviceStoreTests {
    private let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("trusted-\(UUID().uuidString).json")

    /// A record as written before presenceKeyID existed.
    private let oldRecord = """
        [{"deviceId":"phone-a","deviceName":"Pixel","publicKey":"AQI=","fingerprint":"AwQ=",
          "firstSeen":"2026-10-01T10:00:00Z","lastSeen":"2026-10-01T10:00:00Z"}]
        """

    @Test func olderRecordsHaveNoPresenceKeyID() throws {
        try Data(oldRecord.utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = TrustedDeviceStore(fileURL: fileURL)
        store.load()
        #expect(store.devices.count == 1)
        #expect(store.devices.first?.presenceKeyID == nil)
    }

    @Test func notedPresenceKeySurvivesARestart() throws {
        try Data(oldRecord.utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let id = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let store = TrustedDeviceStore(fileURL: fileURL)
        store.load()
        store.notePresenceKey(id, deviceId: "phone-a")
        // A device that isn't trusted is left alone.
        store.notePresenceKey(id, deviceId: "phone-b")

        let reloaded = TrustedDeviceStore(fileURL: fileURL)
        reloaded.load()
        #expect(reloaded.devices.map(\.deviceId) == ["phone-a"])
        #expect(reloaded.devices.first?.presenceKeyID == id)
    }
}
