import XCTest
@testable import IronPetKit

final class ModelsTests: XCTestCase {
    /// What `TaskJSON.json` writes on the Mac: snake_case keys, ISO 8601 dates, empty fields left out, `source_ref` as loose JSON.
    func testDecodesTheMacsTaskJSON() throws {
        let json = #"""
        {"tasks":[{"id":"abc","title":"Review","status":"needs_you","source":"meeting","created":"2026-11-20T08:00:00Z","updated":"2026-11-20T09:30:00Z",
          "due":"2026-11-21T00:00:00Z","waiting_on":"Ana","source_ref":{"meeting":"/x"},"labels":{"merge_mode":"auto"},
          "links":[{"kind":"url","ref":"https://example.com","label":"Doc"}]}]}
        """#
        let list = try WireJSON.makeDecoder().decode(TaskListResponse.self, from: Data(json.utf8))
        let task = try XCTUnwrap(list.tasks.first)
        XCTAssertEqual(task.status, .needsYou)
        XCTAssertEqual(task.waitingOn, "Ana")
        XCTAssertEqual(task.labels, ["merge_mode": "auto"])
        XCTAssertEqual(task.links, [TaskLink(kind: "url", ref: "https://example.com", label: "Doc")])
        XCTAssertEqual(task.notes, "")
        XCTAssertNotNil(task.due)
        XCTAssertFalse(task.needsUser, "a task waiting on someone else never needs the user")
    }

    func testDecodesTaskDetailWithHistory() throws {
        let json = #"""
        {"id":"abc","title":"Review","status":"backlog","source":"user","created":"2026-11-20T08:00:00Z","updated":"2026-11-20T08:00:00Z",
         "history":[{"at":"2026-11-20T08:00:00Z","by":"remote:d1","kind":"note","detail":"hello"}]}
        """#
        let detail = try WireJSON.makeDecoder().decode(RemoteTaskDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.task.id, "abc")
        XCTAssertEqual(detail.history.map(\.by), ["remote:d1"])
    }

    func testDecodesSuggestionsAndEvents() throws {
        let suggestions = #"{"suggestions":[{"id":"s","title":"Send","created":"2026-11-20T08:00:00Z","origin":"automation","origin_detail":"Watcher (a1)","due":"2026-11-25","url":"https://x.dev"}]}"#
        let list = try WireJSON.makeDecoder().decode(SuggestionListResponse.self, from: Data(suggestions.utf8))
        XCTAssertEqual(list.suggestions.first?.originDetail, "Watcher (a1)")
        let event = try WireJSON.makeDecoder().decode(RemoteEvent.self, from: Data(#"{"at":"2026-11-20T08:00:00Z","id":"abc","kind":"tasks.changed","seq":7}"#.utf8))
        XCTAssertEqual(event, RemoteEvent(seq: 7, kind: "tasks.changed", at: event.at, id: "abc"))
        let hello = try WireJSON.makeDecoder().decode(RemoteEvent.self, from: Data(#"{"kind":"hello","seq":3}"#.utf8))
        XCTAssertEqual(hello.kind, RemoteEvent.hello)
    }

    func testRoundTripsTasks() throws {
        let task = RemoteTask(id: "1", title: "T", notes: "n", status: .inProgress, labels: ["a": "b"])
        let data = try WireJSON.makeEncoder().encode(task)
        XCTAssertEqual(try WireJSON.makeDecoder().decode(RemoteTask.self, from: data), task)
    }
}

final class PairingLinkTests: XCTestCase {
    let print = String(repeating: "ab", count: 32)

    func testParsesALink() throws {
        let link = try PairingLink(parsing: "ironpet://pair?u=https://192.168.1.5:47380&c=CODE&f=\(print)")
        XCTAssertEqual(link.baseURL.absoluteString, "https://192.168.1.5:47380")
        XCTAssertEqual(link.code, "CODE")
        XCTAssertEqual(link.fingerprint, print)
    }

    func testParsesEncodedAddressAndColonFingerprint() throws {
        let colons = stride(from: 0, to: 64, by: 2).map { String(print.dropFirst($0).prefix(2)).uppercased() }.joined(separator: ":")
        let link = try PairingLink(parsing: " ironpet://pair?u=http%3A%2F%2F127.0.0.1%3A47380&c=C&f=\(colons)\n")
        XCTAssertEqual(link.baseURL.absoluteString, "http://127.0.0.1:47380")
        XCTAssertEqual(link.fingerprint, print)
    }

    func testFingerprintIsOptional() throws {
        XCTAssertNil(try PairingLink(parsing: "ironpet://pair?u=https://mac.tail1234.ts.net&c=X").fingerprint)
    }

    func testRejectsBadLinks() {
        XCTAssertThrowsError(try PairingLink(parsing: "https://pair?u=http://a&c=b")) { XCTAssertEqual($0 as? PairingLink.ParseError, .notALink) }
        XCTAssertThrowsError(try PairingLink(parsing: "ironpet://pair?c=b")) { XCTAssertEqual($0 as? PairingLink.ParseError, .missingAddress) }
        XCTAssertThrowsError(try PairingLink(parsing: "ironpet://pair?u=http://a")) { XCTAssertEqual($0 as? PairingLink.ParseError, .missingCode) }
        XCTAssertThrowsError(try PairingLink(parsing: "ironpet://pair?u=ftp://a&c=b")) { XCTAssertEqual($0 as? PairingLink.ParseError, .badAddress) }
        XCTAssertThrowsError(try PairingLink(parsing: "ironpet://pair?u=http://a&c=b&f=zz")) { XCTAssertEqual($0 as? PairingLink.ParseError, .badFingerprint) }
    }
}
