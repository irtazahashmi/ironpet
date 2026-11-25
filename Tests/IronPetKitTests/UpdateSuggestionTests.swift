import XCTest
@testable import IronPetKit

/// A suggestion that changes an existing task: the wording the Mac and the phone both show, and the wire form.
final class UpdateSuggestionTests: XCTestCase {
    func testTheHeadlineNamesTheTask() {
        XCTAssertEqual(RemoteSuggestionUpdate(taskID: "t", taskTitle: "Send Tom the deck").headline, "Update: Send Tom the deck")
    }

    func testTheSummaryListsTheChangesInOrder() {
        let all = RemoteSuggestionUpdate(taskID: "t", taskTitle: "x", note: "Sent on Tuesday.", status: "done", waitingOn: "Tom")
        XCTAssertEqual(all.summary, "Mark done. Waiting on Tom. Note: Sent on Tuesday.")
        XCTAssertEqual(RemoteSuggestionUpdate(taskID: "t", taskTitle: "x", status: "done").summary, "Mark done")
        XCTAssertEqual(RemoteSuggestionUpdate(taskID: "t", taskTitle: "x", note: "Ana has it.").summary, "Note: Ana has it.")
        XCTAssertEqual(RemoteSuggestionUpdate(taskID: "t", taskTitle: "x").summary, "No change")
    }

    func testTheUpdateRoundTripsOnTheWire() throws {
        let update = RemoteSuggestionUpdate(taskID: "send-tom-the-deck", taskTitle: "Send Tom the deck", note: "Sent.", status: "done")
        let suggestion = RemoteSuggestion(id: "u-1", title: "Send Tom the deck", origin: "task-scan", update: update)
        let data = try JSONEncoder().encode(suggestion)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wire = try XCTUnwrap(json["update"] as? [String: Any])
        XCTAssertEqual(wire["task_id"] as? String, "send-tom-the-deck")
        XCTAssertEqual(wire["task_title"] as? String, "Send Tom the deck")
        XCTAssertEqual(try JSONDecoder().decode(RemoteSuggestion.self, from: data), suggestion)
    }

    func testASuggestionFromAnOlderMacHasNoUpdate() throws {
        let old = #"{"id":"s","title":"A","created":0,"origin":"meeting"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        XCTAssertNil(try decoder.decode(RemoteSuggestion.self, from: Data(old.utf8)).update)
    }
}
