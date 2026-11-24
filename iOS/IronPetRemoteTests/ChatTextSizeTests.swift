import SwiftUI
import XCTest
@testable import IronPetRemote

final class ChatTextSizeTests: XCTestCase {
    func testDefaultIsOneStepAboveTheOldSize() {
        XCTAssertEqual(ChatTextSize.default, .standard)
        XCTAssertEqual(ChatTextSize.small.steps, 0)
        XCTAssertEqual(ChatTextSize.standard.steps, 1)
        XCTAssertEqual(ChatTextSize.large.steps, 2)
        XCTAssertEqual(ChatTextSize.extraLarge.steps, 3)
    }

    func testAdjustedMovesUpTheDynamicTypeSteps() {
        XCTAssertEqual(ChatTextSize.small.adjusted(.large), .large)
        XCTAssertEqual(ChatTextSize.standard.adjusted(.large), .xLarge)
        XCTAssertEqual(ChatTextSize.extraLarge.adjusted(.large), .xxxLarge)
    }

    func testAdjustedStopsAtTheLargestSize() {
        XCTAssertEqual(ChatTextSize.extraLarge.adjusted(.accessibility5), .accessibility5)
        XCTAssertEqual(ChatTextSize.standard.adjusted(.accessibility5), .accessibility5)
    }

    func testEverySizeHasAUIKitCategory() {
        for size in DynamicTypeSize.allCases { XCTAssertNotEqual(size.contentSizeCategory, .unspecified) }
        XCTAssertEqual(DynamicTypeSize.large.contentSizeCategory, .large)
    }
}

final class ComposerFontTests: XCTestCase {
    func testComposerFontMatchesBubbleFontAtEverySize() {
        for size in DynamicTypeSize.allCases {
            let bubble = ChatMetrics.macBody * ChatScale.value(.body, size)
            XCTAssertEqual(ComposerTextView.font(for: size).pointSize, bubble, accuracy: 0.001)
        }
    }

    func testComposerFontIsFifteenPointsAtTheSystemDefault() {
        XCTAssertEqual(ComposerTextView.font(for: .large).pointSize, 15, accuracy: 0.001)
    }

    func testComposerFontGrowsWithDynamicType() {
        XCTAssertGreaterThan(ComposerTextView.font(for: .xxxLarge).pointSize, ComposerTextView.font(for: .small).pointSize)
    }
}
