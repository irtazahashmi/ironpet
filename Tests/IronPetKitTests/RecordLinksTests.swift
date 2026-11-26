import XCTest
@testable import IronPetKit

final class RecordLinksTests: XCTestCase {
    private func ids(in text: String) -> [String] { RecordLinks.detect(in: text).map(\.id) }

    func testFindsIdsInASentence() {
        XCTAssertEqual(ids(in: "See job_9f3c1e and meeting_abc123."), ["job_9f3c1e", "meeting_abc123"])
        XCTAssertEqual(ids(in: "It is job_9f3c1e."), ["job_9f3c1e"], "a full stop after an id is not part of it")
    }

    func testLeavesPathsFileNamesAndNearMissesAlone() {
        XCTAssertEqual(ids(in: "/Users/me/job_9f3c1e/notes.md"), [], "inside a path")
        XCTAssertEqual(ids(in: "notes.job_9f3c1e.md"), [], "inside a file name")
        XCTAssertEqual(ids(in: "old_job_9f3c1e"), [], "inside a word")
        XCTAssertEqual(ids(in: "job_9f3c1 is too short"), [], "five digits")
        XCTAssertEqual(ids(in: "job_9F3C1E is uppercase"), [], "uppercase")
        XCTAssertEqual(ids(in: "pair_9f3c1e is not a kind"), [], "an unknown prefix")
    }

    func testAnIdBecomesAnIronPetLinkAndBack() throws {
        let url = try XCTUnwrap(RecordLinks.url(for: "job_9f3c1e"))
        XCTAssertEqual(url.absoluteString, "ironpet://job_9f3c1e")
        XCTAssertEqual(RecordLinks.id(from: url), "job_9f3c1e")
    }

    func testOtherLinksAreNotRecordLinks() throws {
        XCTAssertNil(RecordLinks.id(from: try XCTUnwrap(URL(string: "ironpet://pair?u=https://192.168.1.2:8443&c=abc"))), "the pairing link")
        XCTAssertNil(RecordLinks.id(from: try XCTUnwrap(URL(string: "ironpet://job_xyz"))), "not a valid id")
        XCTAssertNil(RecordLinks.id(from: try XCTUnwrap(URL(string: "https://example.com/job_9f3c1e"))), "another scheme")
        XCTAssertNil(RecordLinks.id(from: try XCTUnwrap(URL(string: "ironpet://job_9f3c1e?x=1"))), "a query")
    }
}
