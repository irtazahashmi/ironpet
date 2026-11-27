import XCTest
@testable import IronPet
@testable import IronPetCore

@MainActor
final class TypingDotsTests: XCTestCase {
    private let user = ChatItem(kind: .user("hi"))
    private let text = ChatItem(kind: .assistant("Working on it"))
    private let tool = ChatItem(kind: .tool("ls", ok: nil))

    private func shows(running: Bool = true, _ last: ChatItem?, approvals: Bool = false, forms: Bool = false) -> Bool {
        ChatViewModel.showsTyping(running: running, lastItem: last, hasApprovals: approvals, hasForms: forms)
    }

    func testS1DotsShowBeforeAnyReplyText() {
        XCTAssertTrue(shows(user))
        XCTAssertTrue(shows(ChatItem(kind: .assistant(""))))
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
