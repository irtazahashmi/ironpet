import AppKit
import XCTest
@testable import IronPet

@MainActor
final class MacAccentTests: XCTestCase {
    func testMulticolourSendsNothing() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MacAccentTests.multicolour"))
        defaults.removePersistentDomain(forName: "MacAccentTests.multicolour")
        XCTAssertNil(MacAccent.current(defaults: defaults), "AppleAccentColor is unset for multicolour, so the phone keeps its blue")
    }

    func testAPickedAccentSendsLightAndDarkHex() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MacAccentTests.picked"))
        defaults.set(1, forKey: "AppleAccentColor")
        defer { defaults.removePersistentDomain(forName: "MacAccentTests.picked") }
        let accent = try XCTUnwrap(MacAccent.current(defaults: defaults))
        for value in [accent.light, accent.dark] {
            XCTAssertNotNil(value.range(of: "^#[0-9A-F]{6}$", options: .regularExpression), value)
        }
    }

    func testHexOfAKnownColour() {
        XCTAssertEqual(MacAccent.hex(of: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1), appearance: .aqua), "#FF8000")
    }
}
