import XCTest
@testable import IronPetKit

/// The phone gets each record's public id with the record, and a Mac older than record ids still decodes.
final class RemoteRefTests: XCTestCase {
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    func testRecordsCarryTheirRef() throws {
        XCTAssertEqual(try roundTrip(RemoteMeeting(id: "standup", date: Date(timeIntervalSince1970: 0), ref: "meeting_abc123")).ref, "meeting_abc123")
        XCTAssertEqual(try roundTrip(RemoteAutomation(id: "a1", name: "Digest", ref: "auto_abc123")).ref, "auto_abc123")
        XCTAssertEqual(try roundTrip(RemoteScreenCapture(id: 7, time: Date(timeIntervalSince1970: 0), app: "Xcode", window: "w", ref: "screen_abc123")).ref,
                       "screen_abc123")
    }

    func testARecordWithoutARefStillDecodes() throws {
        XCTAssertNil(try roundTrip(RemoteMeeting(id: "standup", date: Date(timeIntervalSince1970: 0))).ref)
        XCTAssertNil(try roundTrip(RemoteAutomation(id: "a1", name: "Digest")).ref)
    }
}
