import Foundation
import Testing
@testable import LocalDrop

/// Against a real Dewlet on this Mac, only when asked: `TEST_RUNNER_LOCALDROP_MAC_PORT=<port>
/// xcodebuild test …` (the port is in the Mac's Settings › General). A fresh identity that the
/// Mac doesn't know: the handshake must end in `pairing_unavailable` (not in pairing mode) or
/// `pairingRequired`, and the session closes without ever confirming a pairing.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALDROP_MAC_PORT"] != nil, "LOCALDROP_MAC_PORT is not set"))
struct MacIntegrationTests {
    @Test func handshakeWithTheMac() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["LOCALDROP_MAC_PORT"].flatMap(UInt16.init))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MacStore(fileURL: directory.appending(path: "paired-macs.json"))
        do {
            let session = try await ClientSession.open(to: .addresses(["127.0.0.1"], port: port, quick: false), phone: .test(),
                                                       name: "Dewlet test", expected: nil, store: store)
            guard case .pairingRequired(let code, let keyChanged) = session.status else {
                Issue.record("a Mac that never saw this identity trusts it")
                return
            }
            #expect(code.count == 7 && !keyChanged)
            await session.close()
        } catch .peerError(code: ErrorCode.pairingUnavailable) {
            // Not in pairing mode: the full handshake ran and the Mac refused politely.
        }
        #expect(store.macs.isEmpty)
    }
}
