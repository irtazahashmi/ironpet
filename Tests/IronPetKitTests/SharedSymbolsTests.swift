import XCTest
@testable import IronPetKit

final class SharedSymbolsTests: XCTestCase {
    func testTheMacsIconsWonWhereTheAppsDiffered() {
        XCTAssertEqual(SharedSymbols.agents, "person.2")
        XCTAssertEqual(SharedSymbols.automations, "clock.badge.checkmark")
        XCTAssertEqual(SharedSymbols.microphone, "mic")
    }

    func testWindowBackgroundIsTheMacsPair() {
        XCTAssertEqual(SharedTheme.windowLight, 0xFFFFFF)
        XCTAssertEqual(SharedTheme.windowDark, 0x1E1E1E)
    }
}

final class SharedComposerSymbolsTests: XCTestCase {
    func testComposerAndActionSymbols() {
        XCTAssertEqual(SharedSymbols.attach, "paperclip")
        XCTAssertEqual(SharedSymbols.send, "arrow.up")
        XCTAssertEqual(SharedSymbols.stop, "stop.fill")
        XCTAssertEqual(SharedSymbols.newChat, "square.and.pencil")
        XCTAssertEqual(SharedSymbols.settings, "gearshape")
        XCTAssertEqual(SharedSymbols.find, "magnifyingglass")
    }
}
