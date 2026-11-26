import XCTest
@testable import IronPetKit

final class RecordDetailsTests: XCTestCase {
    private func details(_ json: String) throws -> RecordDetails { try RecordDetails(json: Data(json.utf8)) }

    func testTheIdsComeFromTheAnswer() throws {
        let record = try details(#"{"kind":"task","ref":"task_9f3c1e","key":"review-contract"}"#)
        XCTAssertEqual(record.kind, "task")
        XCTAssertEqual(record.ref, "task_9f3c1e")
        XCTAssertEqual(record.key, "review-contract")
        XCTAssertEqual(record.fields, [], "an answer with only the ids has no fields")
        XCTAssertEqual(record.title, "Task")
    }

    func testAnAnswerWithoutItsIdsIsAnError() {
        XCTAssertThrowsError(try details(#"{"kind":"task","ref":"task_9f3c1e"}"#), "no key")
        XCTAssertThrowsError(try details("[1, 2]"), "not an object")
    }

    func testFieldsAreTextInNameOrder() throws {
        let record = try details(#"{"kind":"meeting","ref":"meeting_abc123","key":"2026-11-25 Standup","title":"Standup","minutes":42,"recorded":true,"done":false}"#)
        XCTAssertEqual(record.fields, [
            RecordDetails.Field(name: "done", value: "no"),
            RecordDetails.Field(name: "minutes", value: "42"),
            RecordDetails.Field(name: "recorded", value: "yes"),
            RecordDetails.Field(name: "title", value: "Standup"),
        ])
    }

    func testOneLevelOfNestedObjectsIsFlattenedAndListsAreLeftOut() throws {
        let record = try details(#"{"kind":"task","ref":"task_9f3c1e","key":"k","task":{"title":"Review","status":"needs_you","labels":{"a":"b"}},"history":[{"by":"me"}],"note":null}"#)
        XCTAssertEqual(record.fields, [
            RecordDetails.Field(name: "task.status", value: "needs_you"),
            RecordDetails.Field(name: "task.title", value: "Review"),
        ], "the nested labels object is one level too deep, the list and the null have no text")
    }

    func testAKindWithoutANameShowsItsKind() {
        XCTAssertEqual(RecordDetails(kind: "claim", ref: "claim_1", key: "1", fields: []).title, "Memory claim")
        XCTAssertEqual(RecordDetails(kind: "mystery", ref: "mystery_1", key: "1", fields: []).title, "mystery")
    }
}
