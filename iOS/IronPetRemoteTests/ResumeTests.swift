import XCTest
import IronPetKit
@testable import IronPetRemote

private final class MemoryResumeStore: EventResumeStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: (seq: Int, epoch: String?)?
    init(_ saved: (seq: Int, epoch: String?)? = nil) { self.saved = saved }
    func load() -> (seq: Int, epoch: String?)? { lock.lock(); defer { lock.unlock() }; return saved }
    func save(seq: Int, epoch: String?) { lock.lock(); saved = (seq, epoch); lock.unlock() }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set(_ new: Bool) { lock.lock(); flag = new; lock.unlock() }
}

/// The phone keeps the last event seq it applied and sends it after a reconnect. A Mac that can resume replays the missed events on the
/// same socket, and the phone reads nothing again. The Mac here is the mock server, with `resumeSupported` standing for a new Mac.
@MainActor
final class ResumeTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        server.resumeSupported = true
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func started(store: MemoryResumeStore, socket: FakeChatSocket? = nil) async -> ChatModel {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let connection = EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100)), store: store)
        let model = ChatModel(client: client, events: SharedEventSource(connection), onUnauthorized: {})
        model.socket = socket
        model.start()
        await poll { model.loaded && model.snapshot != nil && self.server.openSocketCount == 1 }
        // The first connect and the first load each read the chat. Wait until the reads stop, so a count taken next is a baseline.
        var last = -1
        while last != chatReads { last = chatReads; try? await Task.sleep(nanoseconds: 150_000_000) }
        return model
    }

    private func poll(_ timeout: Double = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private var chatReads: Int { server.count("GET /v1/chat/current") }

    private func item(_ id: String, _ text: String) -> RemoteChatItem {
        RemoteChatItem(id: id, kind: "assistant", date: Date(timeIntervalSince1970: 1_700_000_100), text: text)
    }

    // S1
    func testAReconnectAfterMissedEventsAppliesThemOnceAndReadsNothingAgain() async {
        let store = MemoryResumeStore()
        let model = await started(store: store)
        let applied = server.publish(RemoteEvent.chatItem, id: "m-3", item: item("m-3", "first"))
        await poll { model.items.contains { $0.id == "m-3" } }
        await poll { store.load()?.seq == applied }
        let readsBefore = chatReads

        server.dropSockets()
        await poll { self.server.openSocketCount == 0 }
        server.publish(RemoteEvent.chatItem, id: "m-4", item: item("m-4", "second"))
        server.publish(RemoteEvent.chatItem, id: "m-5", item: item("m-5", "third"))
        await poll { self.server.socketURLs.count == 2 && model.items.contains { $0.id == "m-5" } }

        XCTAssertEqual(model.items.map(\.id), ["m-1", "m-2", "m-3", "m-4", "m-5"], "each missed message once, in order")
        XCTAssertTrue(server.socketURLs.last?.contains("since=\(applied)") == true, "\(server.socketURLs)")
        XCTAssertTrue(server.socketURLs.last?.contains("epoch=mock-epoch-1") == true)
        XCTAssertEqual(chatReads, readsBefore, "no full refetch")
        XCTAssertEqual(store.load()?.seq, applied + 2)
        model.stop()
    }

    func testTheSavedSeqSurvivesARelaunch() async {
        let store = MemoryResumeStore()
        let first = await started(store: store)
        let seq = server.publish(RemoteEvent.chatItem, id: "m-3", item: item("m-3", "kept"))
        await poll { store.load()?.seq == seq }
        first.stop()
        server.dropSockets()
        server.publish(RemoteEvent.chatItem, id: "m-4", item: item("m-4", "while the app was closed"))
        // A new app process builds a new connection from the same store.
        let second = await started(store: store)
        await poll { second.items.contains { $0.id == "m-4" } }
        XCTAssertTrue(server.socketURLs.last?.contains("since=\(seq)") == true, "\(server.socketURLs)")
        second.stop()
    }

    // S2
    func testASeqOutsideTheBufferMakesOneFullRefetchAndTheStateIsCorrect() async {
        let store = MemoryResumeStore()
        let model = await started(store: store)
        server.publish(RemoteEvent.chatItem, id: "m-3", item: item("m-3", "seen"))
        await poll { model.items.contains { $0.id == "m-3" } }
        let readsBefore = chatReads

        server.dropSockets()
        await poll { self.server.openSocketCount == 0 }
        let seq = server.publish(RemoteEvent.chatItem, id: "m-4", item: item("m-4", "gone from the buffer"))
        server.bufferFloor = seq
        await poll { self.chatReads == readsBefore + 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(chatReads, readsBefore + 1, "exactly one full refetch")
        XCTAssertEqual(store.load()?.seq, seq, "the phone continues from the Mac's seq")
        XCTAssertNil(model.errorMessage)
        model.stop()
    }

    func testAMacLaunchedAgainMakesOneFullRefetch() async {
        let store = MemoryResumeStore()
        let model = await started(store: store)
        let readsBefore = chatReads
        server.dropSockets()
        await poll { self.server.openSocketCount == 0 }
        server.epoch = "mock-epoch-2"
        await poll { self.chatReads == readsBefore + 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(chatReads, readsBefore + 1)
        XCTAssertEqual(store.load()?.epoch, "mock-epoch-2")
        model.stop()
    }

    // S3
    func testAnOlderMacWithoutTheCapabilityFallsBackToAFullRefetchWithNoError() async {
        server.resumeSupported = false
        let store = MemoryResumeStore()
        let model = await started(store: store)
        let readsBefore = chatReads
        server.dropSockets()
        await poll { self.server.openSocketCount == 0 }
        server.publish(RemoteEvent.chatItem, id: "m-9")
        await poll { self.chatReads > readsBefore }
        XCTAssertGreaterThan(chatReads, readsBefore, "the reconnect reads the chat again, as before")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.connectionLost)
        model.stop()
    }

    // S4
    func testWaitingMessagesGoOutAfterTheReplayIsAppliedAndOnceEach() async {
        // The message is typed while the Mac is out of reach, so it waits in the saved outbox.
        let outbox = MemoryOutboxStore()
        let dead = IronPetClient(endpoint: ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:1")!), token: "t")
        let offline = ChatModel(client: dead, events: SharedEventSource(EventConnection(client: dead)), onUnauthorized: {})
        offline.socket = FakeChatSocket(open: false)
        offline.useOutbox(outbox)
        offline.draft = "typed offline"
        await offline.send()
        XCTAssertEqual(offline.outbox.map(\.text), ["typed offline"])

        // The app starts again with the Mac in reach. The phone applied seq K before the Mac produced a message while it was away.
        let store = MemoryResumeStore((seq: server.currentSeq, epoch: server.epoch))
        let socket = FakeChatSocket(open: true)
        let seen = Flag()
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let connection = EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100)), store: store)
        // Reads go to a port nobody listens on, so no full read can bring m-4 in. Only the replay can.
        let model = ChatModel(client: dead, events: SharedEventSource(connection), onUnauthorized: {})
        model.socket = socket
        model.useOutbox(outbox)
        socket.onSend = { [weak model] in
            let applied = await MainActor.run { model?.items.contains { $0.id == "m-4" } == true }
            seen.set(applied)
        }
        server.publish(RemoteEvent.chatItem, id: "m-4", item: item("m-4", "replayed"))
        model.start()
        await poll { !socket.sent.isEmpty }
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(socket.sent.map(\.text), ["typed offline"], "sent once")
        XCTAssertEqual(socket.sent.first?.clientID, offline.outbox.first?.id.uuidString.lowercased(), "with the client id it was made with")
        XCTAssertTrue(seen.value, "the replayed message was applied before the queued one went out")
        model.stop()
    }
}
