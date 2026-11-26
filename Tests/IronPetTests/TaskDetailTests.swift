import XCTest
@testable import IronPet
@testable import IronPetCore

final class TaskDetailTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func labels(_ detail: TaskDetail) -> [String] { detail.fields.map(\.label) }

    func testSuggestionShowsNotesUrlDueAndOrigin() {
        let suggestion = TaskSuggestion(id: "s", title: "Reply", due: "2026-11-20", notes: "Details", url: URL(string: "https://example.com/x"),
                                        origin: .automation(id: "a", name: "PR watcher"), created: now,
                                        sourceRef: #"{"ref":"pr 4","reason":"new review"}"#)
        let detail = TaskDetail(suggestion: suggestion)
        XCTAssertEqual(labels(detail), ["Due", "Origin", "Origin name", "Origin ref", "Origin reason", "Arrived"])
        XCTAssertEqual(detail.fields.first { $0.label == "Origin" }?.value, "automation")
        XCTAssertEqual(detail.notes, "Details")
        XCTAssertEqual(detail.links, [TaskLink(kind: .url, ref: "https://example.com/x")])
    }

    func testAMeetingItemShowsWhereAndWhenItArrivedAndLinksToTheMeeting() {
        let suggestion = TaskSuggestion(id: "s", title: "Send the deck", origin: .meeting(URL(fileURLWithPath: "/m/2026-11-17-0930")), created: now)
        let detail = TaskDetail(suggestion: suggestion)
        XCTAssertEqual(labels(detail), ["Origin", "Origin name", "Arrived"])
        XCTAssertEqual(detail.fields.first { $0.label == "Origin name" }?.value, "Meeting")
        XCTAssertEqual(detail.fields.first { $0.label == "Arrived" }?.value, TaskDetail.time(now))
        XCTAssertEqual(detail.links, [TaskLink(kind: .meeting, ref: "2026-11-17-0930", label: "Meeting")])
    }

    func testPlainTextOriginRefIsKept() {
        XCTAssertEqual(TaskDetail.originFields("not json"), [.init(label: "Origin ref", value: "not json")])
        XCTAssertEqual(TaskDetail.originFields(nil), [])
    }
}
