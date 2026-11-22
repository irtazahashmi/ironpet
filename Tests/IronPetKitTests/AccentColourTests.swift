import XCTest
@testable import IronPetKit

/// The accent the Mac sends with `GET /v1/pet`. A value the phone cannot read leaves its system blue, never a wrong colour.
final class AccentColourTests: XCTestCase {
    func testReadsSixDigitHex() throws {
        let colour = try XCTUnwrap(AccentColour(hex: "#FF9500"))
        XCTAssertEqual(colour.red, 1)
        XCTAssertEqual(colour.green, 149.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(colour.blue, 0)
    }

    func testRefusesAnythingElse() {
        for bad in [nil, "", "FF9500", "#FFF", "#FF95000", "#GG9500", "red"] as [String?] {
            XCTAssertNil(AccentColour(hex: bad), "\(bad ?? "nil")")
        }
    }

    func testNoAccentFromTheMacMeansNoPair() {
        XCTAssertNil(AccentColour.pair(of: nil))
        XCTAssertNil(AccentColour.pair(of: RemotePet(name: "Ghost")))
        XCTAssertNil(AccentColour.pair(of: RemotePet(name: "Ghost", accent: "nonsense", accentDark: "#FF9500")))
    }

    func testDarkFallsBackToLight() throws {
        let pair = try XCTUnwrap(AccentColour.pair(of: RemotePet(name: "Ghost", accent: "#FF9500")))
        XCTAssertEqual(pair.light, pair.dark)
        let both = try XCTUnwrap(AccentColour.pair(of: RemotePet(name: "Ghost", accent: "#FF9500", accentDark: "#FF9F0A")))
        XCTAssertNotEqual(both.light, both.dark)
    }

    func testDecodesTheSnakeCaseKeysAndAnOlderMacWithout() throws {
        let with = ##"{"name":"Ghost","mood":"idle","badge":0,"tricks":[],"background":"default","accent":"#FF9500","accent_dark":"#FF9F0A"}"##
        let pet = try JSONDecoder().decode(RemotePet.self, from: Data(with.utf8))
        XCTAssertEqual(pet.accent, "#FF9500")
        XCTAssertEqual(pet.accentDark, "#FF9F0A")
        let without = #"{"name":"Ghost","mood":"idle","badge":0,"tricks":[],"background":"default"}"#
        let old = try JSONDecoder().decode(RemotePet.self, from: Data(without.utf8))
        XCTAssertNil(old.accent)
    }
}
