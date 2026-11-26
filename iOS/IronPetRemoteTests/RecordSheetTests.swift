import XCTest
import IronPetKit
@testable import IronPetRemote

/// A tapped record link loads the record the Mac names, and shows the Mac's reason when it cannot.
@MainActor
final class RecordSheetTests: XCTestCase {
    func testALoadedRecordIsTheOneTheLinkNamed() async {
        let record = RecordDetails(kind: "meeting", ref: "meeting_abc123", key: "standup", fields: [.init(name: "title", value: "Standup")])
        var asked: [String] = []
        let model = RecordModel(id: "meeting_abc123") { id in
            asked.append(id)
            return record
        }
        await model.load()
        XCTAssertEqual(asked, ["meeting_abc123"])
        XCTAssertEqual(model.state, .loaded(record))
    }

    func testAFailedLoadShowsTheMacsReason() async {
        let model = RecordModel(id: "meeting_000000") { _ in
            throw ClientError.api(status: 404, code: "not_found", message: "no record with id meeting_000000")
        }
        await model.load()
        XCTAssertEqual(model.state, .failed("no record with id meeting_000000"))
    }

    func testALinkOnlyOpensRecordLinks() throws {
        // The chat only hands the sheet ironpet:// record ids. A pairing link is not a record.
        XCTAssertEqual(RecordLinks.id(from: try XCTUnwrap(RecordLinks.url(for: "meeting_9f3c1e"))), "meeting_9f3c1e")
        XCTAssertNil(RecordLinks.id(from: try XCTUnwrap(URL(string: "ironpet://pair?u=https://192.168.1.2:8443&c=abc"))))
    }
}
