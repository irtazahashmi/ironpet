import XCTest
@testable import IronPetCore

final class PromptStoreTests: XCTestCase {
    private var directory: URL!
    private let id = "chat-preamble"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-prompts-\(UUID().uuidString)")
        PromptStore.directory = directory
        PromptStore.defaultText = { Prompts.defaultText($0) }
    }

    override func tearDownWithError() throws {
        PromptStore.defaultText = { Prompts.defaultText($0) }
        try? FileManager.default.removeItem(at: directory)
    }

    private var defaultText: String { Prompts.defaultText(id)! }

    /// Pretends the build shipped a newer default.
    private func shipNewDefault(_ text: String) {
        PromptStore.defaultText = { $0 == self.id ? text : Prompts.defaultText($0) }
    }

    private func fileText(_ path: String) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8)
    }

    func testFirstUseWritesTheDefaultToAFileTheUserCanEdit() {
        XCTAssertEqual(PromptStore.text(id), defaultText)
        XCTAssertEqual(fileText("\(id).md"), defaultText)
        XCTAssertEqual(fileText(".defaults/\(id).md"), defaultText)
        XCTAssertEqual(PromptStore.state(id), .standard)
    }

    func testAnEditIsReadBackAndMarkedEdited() {
        PromptStore.save(id, text: "Only tell me about merged pull requests.")
        XCTAssertEqual(PromptStore.text(id), "Only tell me about merged pull requests.")
        XCTAssertEqual(PromptStore.state(id), .edited)
    }

    func testEditingBackToTheDefaultIsStandardAgain() {
        PromptStore.save(id, text: "changed")
        PromptStore.save(id, text: defaultText)
        XCTAssertEqual(PromptStore.state(id), .standard)
    }

    func testResetRestoresTheDefault() {
        PromptStore.save(id, text: "changed")
        PromptStore.reset(id)
        XCTAssertEqual(PromptStore.text(id), defaultText)
        XCTAssertEqual(PromptStore.state(id), .standard)
    }

    func testAFileThatWasNeverEditedFollowsANewDefaultSilently() {
        _ = PromptStore.text(id)
        shipNewDefault("A newer default.")
        XCTAssertEqual(PromptStore.text(id), "A newer default.")
        XCTAssertEqual(PromptStore.state(id), .standard)
        XCTAssertNil(PromptStore.pendingUpdate(id))
    }

    func testAnEditedFileKeepsTheUsersTextWhenTheDefaultChanges() {
        PromptStore.save(id, text: "Mine.")
        shipNewDefault("A newer default.")
        XCTAssertEqual(PromptStore.text(id), "Mine.")
        XCTAssertEqual(PromptStore.state(id), .updated)
        let pending = PromptStore.pendingUpdate(id)
        XCTAssertEqual(pending?.previous, defaultText)
        XCTAssertEqual(pending?.current, "A newer default.")
    }

    func testKeepMineStopsTheUpdateNotice() {
        PromptStore.save(id, text: "Mine.")
        shipNewDefault("A newer default.")
        PromptStore.keepMine(id)
        XCTAssertEqual(PromptStore.text(id), "Mine.")
        XCTAssertEqual(PromptStore.state(id), .edited)
        XCTAssertNil(PromptStore.pendingUpdate(id))
    }

    func testUseNewDefaultReplacesTheUsersText() {
        PromptStore.save(id, text: "Mine.")
        shipNewDefault("A newer default.")
        PromptStore.reset(id)
        XCTAssertEqual(PromptStore.text(id), "A newer default.")
        XCTAssertEqual(PromptStore.state(id), .standard)
    }

    func testAFileWithNoRecordOfItsDefaultIsTreatedAsAnEdit() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "Hand written.".write(to: directory.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PromptStore.text(id), "Hand written.")
        XCTAssertEqual(PromptStore.state(id), .edited)
        shipNewDefault("A newer default.")
        XCTAssertEqual(PromptStore.text(id), "Hand written.", "a hand-written file must not be overwritten by a later default")
        XCTAssertEqual(PromptStore.state(id), .updated)
    }

    func testAnUnknownIdHasNoTextAndSavesNothing() {
        XCTAssertEqual(PromptStore.text("no-such-prompt"), "")
        PromptStore.save("no-such-prompt", text: "x")
        XCTAssertNil(fileText("no-such-prompt.md"))
    }

    // MARK: Rendering

    func testPlaceholdersAreFilledInOnePassAndValuesAreNotScannedAgain() {
        let out = Prompts.render("Hi {name}, {unknown} stays. {transcript}", ["name": "Ana", "transcript": "{name} {unknown}"])
        XCTAssertEqual(out, "Hi Ana, {unknown} stays. {name} {unknown}")
    }

    func testAnUnclosedBraceIsKeptAsWritten() {
        XCTAssertEqual(Prompts.render("a { b {name}", ["name": "x"]), "a { b x")
        XCTAssertEqual(Prompts.render("tail {", ["name": "x"]), "tail {")
    }

    func testARequiredValueTheTextLeavesOutIsAppended() {
        PromptStore.save("automation-prompt", text: "Plain text only.")
        XCTAssertEqual(Prompts.render(id: "automation-prompt", ["name": "A", "prompt": "Check it."]), "Plain text only.\n\nCheck it.")
    }

    func testTheDiffListsRemovedAndAddedLinesInOrder() {
        let changes = Prompts.diff(from: "one\ntwo\nthree", to: "one\n2\nthree\nfour")
        XCTAssertEqual(changes, [
            Prompts.LineChange(removed: true, line: "two"),
            Prompts.LineChange(removed: false, line: "2"),
            Prompts.LineChange(removed: false, line: "four"),
        ])
    }

    // MARK: Defaults

    func testTheShippedDefaultsAreTheFilesInThePromptsFolder() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent("prompts").path)
            .filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
        XCTAssertEqual(files, BuiltInPromptsData.all.map(\.id).sorted(), "a prompt file is not compiled in, or the other way round. Run scripts/gen_prompts.py")
        for prompt in BuiltInPromptsData.all {
            let text = try String(contentsOf: repo.appendingPathComponent("prompts/\(prompt.id).md"), encoding: .utf8)
            XCTAssertEqual(prompt.text, text.hasSuffix("\n") ? String(text.dropLast()) : text, "prompts/\(prompt.id).md changed. Run scripts/gen_prompts.py")
        }
    }

    @MainActor
    func testTheMeetingSummaryDefaultIsUnchanged() throws {
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/prompts/meeting-summary.txt")
        let expected = try String(contentsOf: golden, encoding: .utf8)
        XCTAssertEqual(MeetingSummary.prompt(transcript: "TRANSCRIPT"), expected)
    }

    func testTheAutomationWrapperDefaultIsUnchanged() {
        XCTAssertEqual(Prompts.render(id: "automation-prompt", ["name": "Morning brief", "prompt": "Check it."]),
                       "This is an automated run of \"Morning brief\" from ironpet. Answer in under 600 characters, as plain text for a small notification.\n\nCheck it.")
    }
}
