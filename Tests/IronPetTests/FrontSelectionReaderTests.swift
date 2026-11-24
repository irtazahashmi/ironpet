import AppKit
import XCTest
@testable import IronPet
@testable import IronPetCore

@MainActor
final class FrontSelectionReaderTests: XCTestCase {
    func testUntrustedAccessibilityReturnsNil() {
        let app = NSRunningApplication.current
        XCTAssertNil(FrontSelectionReader.read(from: app, isTrusted: { false }))
    }

    func testOwnAppIsIgnoredEvenWhenTrusted() {
        let app = NSRunningApplication.current
        let own = Bundle.main.bundleIdentifier ?? "com.ironpet.app"
        XCTAssertNil(FrontSelectionReader.read(from: app, ownBundleId: own, isTrusted: { true }))
    }

    func testNilAppReturnsNil() {
        XCTAssertNil(FrontSelectionReader.read(from: nil, isTrusted: { true }))
    }
}
