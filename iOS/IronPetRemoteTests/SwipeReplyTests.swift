import XCTest
@testable import IronPetRemote

/// Step 7 of #190: the numbers behind the swipe that starts a reply.
final class SwipeReplyTests: XCTestCase {
    func testThePullFollowsTheFingerAtAFractionAndStopsAtTheMaximum() {
        XCTAssertEqual(SwipeReply.pull(-20), 0)
        XCTAssertEqual(SwipeReply.pull(100), 100 * SwipeReply.follow, accuracy: 0.001)
        XCTAssertEqual(SwipeReply.pull(1000), SwipeReply.maxPull)
    }

    func testTheThresholdIsCrossedOnlyByALongEnoughPull() {
        XCTAssertFalse(SwipeReply.crossed(30))
        XCTAssertFalse(SwipeReply.crossed(SwipeReply.threshold / SwipeReply.follow - 1))
        XCTAssertTrue(SwipeReply.crossed(SwipeReply.threshold / SwipeReply.follow + 1))
    }

    func testOnlyAMostlyHorizontalRightDragAwayFromTheEdgeBegins() {
        XCTAssertTrue(SwipeReply.begins(dx: 40, dy: 5, startX: 100))
        XCTAssertFalse(SwipeReply.begins(dx: -40, dy: 5, startX: 100), "a left drag is not a reply")
        XCTAssertFalse(SwipeReply.begins(dx: 40, dy: 30, startX: 100), "a diagonal drag is a scroll")
        XCTAssertFalse(SwipeReply.begins(dx: 40, dy: 5, startX: SwipeReply.edge - 1), "the edge belongs to the back swipe")
    }
}
