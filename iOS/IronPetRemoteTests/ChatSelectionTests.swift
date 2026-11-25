import IronPetKit
import XCTest
@testable import IronPetRemote

/// The text a selection quotes and the reply state that carries it.
@MainActor
final class ChatSelectionTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func model() -> ChatModel {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        return ChatModel(client: client, events: events, onUnauthorized: {})
    }

    func testQuotableDropsListMarkersAndCheckboxes() {
        let selection = "first line\n\t•\talpha\n\t2.\tbeta\n\t\u{FFFC}\tdone item"
        XCTAssertEqual(SelectableTextBuilder.quotable(selection), "first line\nalpha\nbeta\ndone item")
    }

    func testQuotableOfOnlyWhitespaceIsEmpty() {
        XCTAssertEqual(SelectableTextBuilder.quotable("\n \t "), "")
    }

    func testReplyKeepsTheTrimmedSelection() {
        let model = model()
        let item = RemoteChatItem(id: "m-1", kind: "assistant", date: Date(), text: "hello there")
        model.reply(to: item, selection: "  there \n")
        XCTAssertEqual(model.replyTo?.id, "m-1")
        XCTAssertEqual(model.replySelection, "there")
    }

    func testABlankSelectionQuotesTheWholeMessage() {
        let model = model()
        let item = RemoteChatItem(id: "m-1", kind: "assistant", date: Date(), text: "hello there")
        model.reply(to: item, selection: " \n")
        XCTAssertNil(model.replySelection)
        model.reply(to: item)
        XCTAssertNil(model.replySelection)
    }

    func testClearingOrChangingTheReplyDropsTheSelection() {
        let model = model()
        let first = RemoteChatItem(id: "m-1", kind: "assistant", date: Date(), text: "one")
        let second = RemoteChatItem(id: "m-2", kind: "assistant", date: Date(), text: "two")
        model.reply(to: first, selection: "one")
        model.replyTo = nil
        XCTAssertNil(model.replySelection)
        model.reply(to: first, selection: "one")
        model.replyTo = second
        XCTAssertNil(model.replySelection)
    }
}
