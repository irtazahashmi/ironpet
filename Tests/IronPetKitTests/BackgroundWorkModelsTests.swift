import XCTest
@testable import IronPetKit

final class BackgroundWorkModelsTests: XCTestCase {
    func testAMacThatSendsNoBackgroundListDecodesToEmpty() throws {
        let snapshot = try WireJSON.makeDecoder().decode(RemoteChatSnapshot.self, from: Data("{\"title\":\"Chat\"}".utf8))
        XCTAssertTrue(snapshot.background.isEmpty)
    }

    func testARowDecodesFromTheWireAndMissingFieldsTakeDefaults() throws {
        let json = """
        {"background":[{"id":"sh-1","kind":"shell","title":"npm run dev","state":"running","started_at":"2026-11-27T10:00:00Z","can_stop":true,
        "lines":["a","b"],"now":"b"},{"id":"x"}]}
        """
        let snapshot = try WireJSON.makeDecoder().decode(RemoteChatSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.background.count, 2)
        XCTAssertEqual(snapshot.background[0].lines, ["a", "b"])
        XCTAssertTrue(snapshot.background[0].stoppable)
        XCTAssertEqual(snapshot.background[1].state, "running")
        XCTAssertFalse(snapshot.background[1].canStop)
    }

    func testCapsulePriorityIsFailedThenWaitingThenRunning() {
        let states: [(id: String, state: String)] = [("a", "running"), ("b", "waiting"), ("c", "failed"), ("d", "done")]
        XCTAssertEqual(BackgroundCapsule.make(states: states, seenFailures: []), .failed(1))
        XCTAssertEqual(BackgroundCapsule.make(states: states, seenFailures: ["c"]), .waiting(1))
        XCTAssertEqual(BackgroundCapsule.make(states: [("a", "running"), ("d", "done")], seenFailures: []), .running(1))
        XCTAssertEqual(BackgroundCapsule.make(states: [("d", "done")], seenFailures: []), .idle)
        XCTAssertEqual(BackgroundCapsule.running(2).label, "2 running")
    }

    func testElapsedAndSubtitleText() {
        XCTAssertEqual(BackgroundWorkStyle.elapsed(372), "6:12")
        XCTAssertEqual(BackgroundWorkStyle.elapsed(3723), "1:02:03")
        XCTAssertEqual(BackgroundWorkStyle.subtitle(state: "waiting", now: nil, waitingFor: "Allow x?", result: nil, steps: 0, kind: "job"), "Needs approval · Allow x?")
        XCTAssertEqual(BackgroundWorkStyle.subtitle(state: "running", now: "Read", waitingFor: nil, result: nil, steps: 3, kind: "agent"), "Read · 3 steps")
        XCTAssertEqual(BackgroundWorkStyle.subtitle(state: "done", now: nil, waitingFor: nil, result: "48 tests\nmore", steps: 0, kind: "shell"), "Done · 48 tests")
    }
}
