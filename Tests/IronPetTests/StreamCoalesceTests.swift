import XCTest
@testable import IronPet
@testable import IronPetCore

/// A reply streaming into a long thread: the text stays complete and in order, and the chat publishes only what changed.
@MainActor
final class StreamCoalesceTests: XCTestCase {
    private var h: ChatHarness!
    private var deliver: [(AgentEvent) -> Void] = []

    override func setUp() async throws {
        TestMemory.isolate()
        h = ChatHarness()
        h.session.workspace = FileManager.default.temporaryDirectory
        h.session.turnRunner = { [unowned self] _, emit in deliver.append(emit) }
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        await h.model.settle()
    }

    private func start(withItems count: Int) async {
        await h.type("go")
        await settle()
        let older: [ChatSession.Item] = (0..<count).map { .init(kind: $0 % 2 == 0 ? .user("q\($0)") : .assistant("a\($0)")) }
        h.session.items.insert(contentsOf: older, at: 0)
    }

    func testS1LongThreadKeepsTheWholeReplyAndPublishesOnlyTheLastItem() async {
        await start(withItems: 17_000)
        var published: [String?] = []
        let subscription = h.events.subscribe { if $0.kind == .chatItem { published.append($0.id) } }
        defer { subscription.cancel() }
        let chunks = (0..<500).map { "w\($0) " }
        chunks.forEach { deliver[0](.assistant($0)) }
        guard case .assistant(let text) = h.session.items.last?.kind else { return XCTFail("no reply") }
        XCTAssertEqual(text, chunks.joined())
        XCTAssertEqual(published.count, 500)
        XCTAssertEqual(Set(published).count, 1, "every update names the last item, none asks for a full re-read")
        XCTAssertEqual(published.first, h.session.items.last?.id.uuidString)
    }

    func testS2ActivityIsPublishedOncePerRunNotOncePerChunk() async {
        await start(withItems: 10)
        var status = 0
        let subscription = h.events.subscribe { if $0.kind == .chatState, $0.id == "status" { status += 1 } }
        defer { subscription.cancel() }
        for i in 0..<200 { deliver[0](.assistant("c\(i)")) }
        XCTAssertEqual(h.session.activity, "Writing")
        XCTAssertEqual(status, 1)
    }
}
