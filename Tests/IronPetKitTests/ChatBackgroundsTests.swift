import SwiftUI
import XCTest
@testable import IronPetKit

/// The built-in chat backgrounds are one table that the Mac and the iPhone app both draw from, so a change to it is a change to both.
final class ChatBackgroundsTests: XCTestCase {
    func testTheTableIsTheOneTheMacShips() {
        let rows = ChatBackgrounds.builtIns.map { "\($0.id) \(String($0.light.0, radix: 16)) \(String($0.light.1, radix: 16)) \(String($0.dark.0, radix: 16)) \(String($0.dark.1, radix: 16)) \(String($0.lightInk, radix: 16)) \(String($0.darkInk, radix: 16)) \($0.inkOpacity) \($0.doodles.map { "\($0)" }.joined(separator: ","))" }
        XCTAssertEqual(rows, [
            "dusk f6f8fd eef2fb 1f2233 181d2b 0 ffffff 0.0 ",
            "paws f2faf5 e9f6ef 1a2a24 15221d 2f6b4f a8e0c6 0.04 paw,star",
            "ghosts f8f4fd f1ecfb 25203a 1c1830 5b4a8c c9bdf2 0.035 ghost,star,bubble",
            "chatter fef7ef fbefe2 2e2420 241c19 9a5b2e f0c7a0 0.04 bubble,star,paw",
            "leaves f4f9ef ebf4e1 1e2818 182012 4b7a2e bee3a0 0.04 leaf,star",
        ])
    }

    func testLookupAndSpecialIDs() {
        XCTAssertEqual(ChatBackgrounds.builtIn("paws")?.name, "Paws")
        XCTAssertNil(ChatBackgrounds.builtIn(ChatBackgrounds.defaultID))
        XCTAssertNil(ChatBackgrounds.builtIn(ChatBackgrounds.customID))
        XCTAssertEqual(Set(ChatBackgrounds.builtIns.map(\.id)).count, ChatBackgrounds.builtIns.count)
    }

    func testEveryDoodleHasAPath() {
        for doodle in ChatBackgrounds.Doodle.allCases { XCTAssertFalse(BuiltInBackgroundView.path(doodle).isEmpty) }
    }
}
