import XCTest
@testable import IronPetRemote
import IronPetKit

@MainActor
final class StreamingBubbleTests: XCTestCase {
    private let reply = RemoteChatItem(id: "2", kind: "assistant", text: "Working on it")
    private let tool = RemoteChatItem(id: "3", kind: "tool", text: "ls")

    func testS4TheNewestReplyIsStreamingWhileARunGoes() {
        XCTAssertEqual(ChatModel.streamingItemID(running: true, last: reply), "2")
    }

    func testS4TheTimeAndSpeakerButtonReturnWhenTheRunEnds() {
        XCTAssertNil(ChatModel.streamingItemID(running: false, last: reply))
    }

    func testS4OnlyAReplyStreamsNotATool() {
        XCTAssertNil(ChatModel.streamingItemID(running: true, last: tool))
        XCTAssertNil(ChatModel.streamingItemID(running: true, last: nil))
    }
}
