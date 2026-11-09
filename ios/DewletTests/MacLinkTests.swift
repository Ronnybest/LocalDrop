import Foundation
import Testing
@testable import LocalDrop

/// The foreground link against `FakeMac`: one session, receive rounds on it, queued sends in
/// between, a polite close.
@Suite(.timeLimit(.minutes(1)))
struct MacLinkTests {
    private let directory: URL
    private let store: MacStore
    private let phone = Phone.test()

    init() throws {
        directory = try temporaryDirectory()
        store = MacStore(fileURL: directory.appending(path: "Dewlet/paired-macs.json"))
    }

    @Test func oneSessionForPollsAndSends() async throws {
        let mac = try FakeMac()
        try store.trust(mac.paired())
        let server = Task { () throws -> (rounds: Int, files: [String: Data], last: [String]) in
            let peer = try await mac.trustedSession()
            var rounds = 0
            var files: [String: Data] = [:]
            var deliveredText = false
            while true {
                let message = try await peer.channel.receive(timeout: 10, stage: "next")
                switch message.type {
                case MessageType.receiveReady:
                    rounds += 1
                    if !files.isEmpty && !deliveredText {
                        try await peer.channel.send(OutgoingMessages.text(Data(count: 16), text: "https://example.com"))
                        try await peer.channel.receive(timeout: 5, stage: "text_result").expect(MessageType.textResult)
                        deliveredText = true
                    }
                    try await peer.channel.send(OutgoingMessages.nothingPending)
                case MessageType.transferRequest:
                    files = try await mac.receiveTransfer(peer.channel, request: message)
                default:
                    await peer.channel.closeConnection()
                    return (rounds, files, [message.type])
                }
            }
        }
        let delegate = LinkLog(directory: directory)
        let link = MacLink(mac: mac.paired(), phone: phone, delegate: delegate, store: store)
        link.start()
        let file = directory.appending(path: "notes.pdf")
        try Data(repeating: 1, count: 1234).write(to: file)
        try await link.send([try OutgoingItem.file(file)])
        #expect(link.state == .connected && link.activity == nil)
        #expect(delegate.sent == ["notes.pdf"])

        for _ in 0..<100 where delegate.received.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        guard case .text(let text)? = delegate.received.first else { Issue.record("nothing received"); return }
        #expect(text == "https://example.com")
        link.stop()
        let (rounds, files, last) = try await server.value
        #expect(rounds >= 1 && files["notes.pdf"]?.count == 1234 && last == [MessageType.close])
        for _ in 0..<50 where link.state != .idle { try await Task.sleep(for: .milliseconds(20)) }
        #expect(link.state == .idle)
    }

    @Test func stoppingLeavesAnOfferUnanswered() async throws {
        let mac = try FakeMac()
        try store.trust(mac.paired())
        let server = Task { () throws -> String? in
            let peer = try await mac.trustedSession()
            try await peer.channel.receive(timeout: 10, stage: "receive_ready").expect(MessageType.receiveReady)
            try await peer.channel.send(OutgoingMessages.request(Data(repeating: 6, count: 16), files: [
                TransferFileInfo(fileId: 0, name: "a.zip", mimeType: "application/zip", size: 5, lastModified: nil),
            ]))
            // TransferSender's acceptance read: EOF keeps the delivery (interrupted); any answer deletes it.
            let answer = try? await peer.channel.receive(timeout: 10, stage: "acceptance")
            await peer.channel.closeConnection()
            return answer?.type
        }
        let delegate = LinkLog(directory: directory)
        let link = MacLink(mac: mac.paired(), phone: phone, delegate: delegate, store: store)
        link.start()
        for _ in 0..<100 where link.activity == nil { try await Task.sleep(for: .milliseconds(50)) }
        guard case .awaitingDecision? = link.activity else { Issue.record("no offer"); return }
        link.stop()
        #expect(try await server.value == nil)
        for _ in 0..<50 where link.state != .idle { try await Task.sleep(for: .milliseconds(20)) }
        #expect(link.state == .idle && link.activity == nil && delegate.failures.isEmpty)
    }

    @Test func aSendQueuedAfterStopStillGoes() async throws {
        let mac = try FakeMac()
        try store.trust(mac.paired())
        let server = Task { () throws -> (files: [String: Data], last: String?) in
            let peer = try await mac.trustedSession()
            var files: [String: Data] = [:]
            while true {
                let message = try await peer.channel.receive(timeout: 10, stage: "next")
                guard message.type == MessageType.transferRequest else {
                    await peer.channel.closeConnection()
                    return (files, message.type)
                }
                files = try await mac.receiveTransfer(peer.channel, request: message)
            }
        }
        let link = MacLink(mac: mac.paired(), phone: phone, delegate: LinkLog(directory: directory), store: store)
        link.start()
        link.stop()
        let file = directory.appending(path: "late.pdf")
        try Data(repeating: 2, count: 4321).write(to: file)
        try await link.send([try OutgoingItem.file(file)])
        // Sent, then closed: no receive round while stopping.
        let (files, last) = try await server.value
        #expect(files["late.pdf"]?.count == 4321 && last == MessageType.close)
        for _ in 0..<50 where link.state != .idle { try await Task.sleep(for: .milliseconds(20)) }
        #expect(link.state == .idle)
    }

    @Test func aMacThatForgotThisIPhone() async throws {
        let mac = try FakeMac()
        try store.trust(mac.paired())
        let server = Task {
            let peer = try await mac.handshake(try await mac.accept())
            try await peer.channel.send(ErrorMessage(code: ErrorCode.pairingUnavailable).message)
            peer.frames.cancel()
        }
        let link = MacLink(mac: mac.paired(), phone: phone, delegate: LinkLog(directory: directory), store: store)
        link.start()
        for _ in 0..<100 where link.state != .notPaired { try await Task.sleep(for: .milliseconds(50)) }
        #expect(link.state == .notPaired)
        try await server.value
        link.stop()
    }
}

@MainActor final class LinkLog: MacLinkDelegate {
    let receiveDirectory: URL
    private(set) var received: [ReceivedItem] = []
    private(set) var sent: [String] = []
    private(set) var failures: [ClientError] = []

    init(directory: URL) { receiveDirectory = directory }

    func link(_ link: MacLink, received items: [ReceivedItem], from macName: String) { received += items }
    func link(_ link: MacLink, finishedSending summary: String, to macName: String) { sent.append(summary) }
    func link(_ link: MacLink, failed error: ClientError, macName: String) { failures.append(error) }
}
