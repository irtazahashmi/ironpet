import XCTest
@testable import IronPetKit

final class ModelsTests: XCTestCase {
    /// A Mac from before the Inbox sends `update` and `clarify` on a suggestion. The phone ignores both and still decodes the item.
    func testDecodesAnOlderMacsSuggestion() throws {
        let json = #"""
        {"suggestions":[{"id":"s","title":"Send","created":"2026-11-20T08:00:00Z","origin":"task-scan","origin_detail":"Task scan",
          "update":{"task":"t1","summary":"Mark done"},"clarify":{"summary":"Files as Mac"},"future_key":1}]}
        """#
        let list = try WireJSON.makeDecoder().decode(SuggestionListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(list.suggestions.map(\.id), ["s"])
        XCTAssertEqual(list.suggestions.first?.origin, "task-scan")
    }

    func testDecodesSuggestionsAndEvents() throws {
        let suggestions = #"{"suggestions":[{"id":"s","title":"Send","created":"2026-11-20T08:00:00Z","origin":"automation","origin_detail":"Watcher (a1)","due":"2026-11-25","url":"https://x.dev"}]}"#
        let list = try WireJSON.makeDecoder().decode(SuggestionListResponse.self, from: Data(suggestions.utf8))
        XCTAssertEqual(list.suggestions.first?.originDetail, "Watcher (a1)")
        let event = try WireJSON.makeDecoder().decode(RemoteEvent.self, from: Data(#"{"at":"2026-11-20T08:00:00Z","id":"abc","kind":"suggestions.changed","seq":7}"#.utf8))
        XCTAssertEqual(event, RemoteEvent(seq: 7, kind: "suggestions.changed", at: event.at, id: "abc"))
        let hello = try WireJSON.makeDecoder().decode(RemoteEvent.self, from: Data(#"{"kind":"hello","seq":3}"#.utf8))
        XCTAssertEqual(hello.kind, RemoteEvent.hello)
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
