import SwiftUI
import XCTest
@testable import IronPetKit

/// The built-in chat backgrounds are one table that the Mac and the iPhone app both draw from, so a change to it is a change to both.
final class ChatBackgroundsTests: XCTestCase {
    func testTheTableIsTheOneTheMacShips() {
        let rows = ChatBackgrounds.builtIns.map { "\($0.id) \(String($0.light.0, radix: 16)) \(String($0.light.1, radix: 16)) \(String($0.dark.0, radix: 16)) \(String($0.dark.1, radix: 16)) \(String($0.lightInk, radix: 16)) \(String($0.darkInk, radix: 16)) \($0.inkOpacity) \($0.doodles.map { "\($0)" }.joined(separator: ","))" }
        XCTAssertEqual(rows, [
            "dusk f6f8fd eef2fb 1f2233 181d2b 0 ffffff 0.0 ",
            "paws f2faf5 e9f6ef 1a2a24 15221d 2f6b4f a8e0c6 0.08 paw,star",
            "ghosts f8f4fd f1ecfb 25203a 1c1830 5b4a8c c9bdf2 0.07 ghost,star,bubble",
            "chatter fef7ef fbefe2 2e2420 241c19 9a5b2e f0c7a0 0.08 bubble,star,paw",
            "leaves f4f9ef ebf4e1 1e2818 182012 4b7a2e bee3a0 0.08 leaf,star",
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

    /// The doodles are drawn at an opacity that stays visible, and a link on a stroke stays at 4.5:1 or better.
    func testLinksStayReadableOnADoodleStroke() {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func rgb(_ hex: UInt32) -> [Double] { [Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF)] }
        func luminance(_ c: [Double]) -> Double { 0.2126 * lin(c[0] / 255) + 0.7152 * lin(c[1] / 255) + 0.0722 * lin(c[2] / 255) }
        func ratio(_ a: [Double], _ b: [Double]) -> Double { let x = luminance(a), y = luminance(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
        // The system link colour is about this in each appearance.
        let linkLight: [Double] = [0, 0x5A, 0xC8], linkDark: [Double] = [0x4D, 0xA3, 0xFF]
        for b in ChatBackgrounds.builtIns where !b.doodles.isEmpty {
            XCTAssertGreaterThanOrEqual(b.inkOpacity, 0.07, "\(b.id) doodles are visible")
            for (dark, link, colors, ink, alpha) in [(false, linkLight, [b.light.0, b.light.1], b.lightInk, b.inkOpacity),
                                                     (true, linkDark, [b.dark.0, b.dark.1], b.darkInk, b.inkOpacity * 1.2)] {
                for color in colors {
                    let stroke = zip(rgb(ink), rgb(color)).map { $0 * alpha + $1 * (1 - alpha) }
                    XCTAssertGreaterThanOrEqual(ratio(link, stroke), 4.5, "\(b.id) \(dark ? "dark" : "light") link on a stroke")
                }
            }
        }
    }
}
