import XCTest
@testable import IronPetRemote
import IronPetKit

@MainActor
final class TypingDotsTests: XCTestCase {
    private let user = RemoteChatItem(id: "1", kind: "user", text: "hi")
    private let text = RemoteChatItem(id: "2", kind: "assistant", text: "Working on it")
    private let tool = RemoteChatItem(id: "3", kind: "tool", text: "ls")

    private func shows(running: Bool = true, _ last: RemoteChatItem?, approvals: Bool = false, forms: Bool = false) -> Bool {
        ChatModel.showsTyping(running: running, last: last, hasApprovals: approvals, hasForms: forms)
    }

    func testS1DotsShowBeforeAnyReplyText() {
        XCTAssertTrue(shows(user))
        XCTAssertTrue(shows(RemoteChatItem(id: "4", kind: "assistant", text: "")))
    }

    func testS2DotsHideOnTheFirstTextChunk() { XCTAssertFalse(shows(text)) }

    func testS3DotsReturnWhenAToolRunsAndHideOnTheNextText() {
        XCTAssertTrue(shows(tool))
        XCTAssertFalse(shows(text))
    }

    func testS4NoDotsWhenTheRunEnded() {
        XCTAssertFalse(shows(running: false, user))
        XCTAssertFalse(shows(running: false, tool))
    }

    func testS5ApprovalsAndFormsHideTheDots() {
        XCTAssertFalse(shows(user, approvals: true))
        XCTAssertFalse(shows(tool, forms: true))
    }
}
