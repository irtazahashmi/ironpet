import XCTest

extension XCUIApplication {
    /// Types the pairing link into the pairing field once the field has keyboard focus.
    /// A tap right after launch can land before the field takes focus, and `typeText` then
    /// fails with "Neither element nor any descendant has keyboard focus". The helper taps,
    /// waits up to 5 seconds for focus, and taps once more if the first tap did not take.
    func enterPairingLink(_ link: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = descendants(matching: .any)["pairing-link-field"]
        XCTAssertTrue(field.appears(timeout: 10), "the pairing field appears", file: file, line: line)
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<2 {
            field.tap()
            let wait = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 5)
            if wait == .completed { break }
        }
        XCTAssertTrue(field.hasKeyboardFocus, "the pairing field has keyboard focus", file: file, line: line)
        field.typeText(link)
    }
}

extension XCUIElement {
    fileprivate var hasKeyboardFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
