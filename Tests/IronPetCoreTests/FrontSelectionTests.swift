import XCTest
@testable import IronPetCore

final class FrontSelectionTests: XCTestCase {
    func testMakeTrimsAndBuildsSourceLabel() {
        let selection = FrontSelection.make(text: "  hello world  ", appName: "Notes", windowTitle: " Shopping ")
        XCTAssertEqual(selection?.text, "hello world")
        XCTAssertEqual(selection?.appName, "Notes")
        XCTAssertEqual(selection?.windowTitle, "Shopping")
        XCTAssertEqual(selection?.sourceLabel, "Notes — Shopping")
        XCTAssertEqual(selection?.trimmed, false)
    }

    func testMakeWithoutWindowUsesAppNameAlone() {
        let selection = FrontSelection.make(text: "hi", appName: "Mail", windowTitle: "  ")
        XCTAssertEqual(selection?.sourceLabel, "Mail")
        XCTAssertNil(selection?.windowTitle)
    }

    func testMakeReturnsNilForEmptyTextOrApp() {
        XCTAssertNil(FrontSelection.make(text: "   ", appName: "Notes", windowTitle: nil))
        XCTAssertNil(FrontSelection.make(text: "hi", appName: "  ", windowTitle: nil))
    }

    func testMakeCapsAtLimitAndMarksTrimmed() throws {
        let long = String(repeating: "x", count: FrontSelection.limit + 50)
        let selection = try XCTUnwrap(FrontSelection.make(text: long, appName: "Chrome", windowTitle: nil))
        XCTAssertEqual(selection.text.count, FrontSelection.limit)
        XCTAssertTrue(selection.trimmed)
        let prompt = FrontSelection.prompt(selection, text: "summarize")
        XCTAssertTrue(prompt.hasPrefix("> From Chrome:"))
        XCTAssertTrue(prompt.contains("was cut here"))
        XCTAssertTrue(prompt.hasSuffix("\n\nsummarize"))
    }

    func testPromptQuotesEveryLine() {
        let selection = FrontSelection(text: "line one\nline two", appName: "Slack", windowTitle: "general")
        let prompt = FrontSelection.prompt(selection, text: "reply to this")
        XCTAssertEqual(prompt, """
            > From Slack — general:
            > line one
            > line two

            reply to this
            """)
    }
}
