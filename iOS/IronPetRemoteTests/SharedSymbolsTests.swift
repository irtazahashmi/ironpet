import IronPetKit
import XCTest
@testable import IronPetRemote

final class SharedSymbolsTests: XCTestCase {
    func testTabsReadTheSharedTable() {
        XCTAssertEqual(AppTab.pet.symbol, SharedSymbols.pet)
        XCTAssertEqual(AppTab.chat.symbol, SharedSymbols.chat)
        XCTAssertEqual(AppTab.tasks.symbol, SharedSymbols.tasks)
        XCTAssertEqual(AppTab.agents.symbol, SharedSymbols.agents)
        XCTAssertEqual(AppTab.more.symbol, SharedSymbols.more)
    }
}
