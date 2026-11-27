import AppKit
import XCTest
@testable import IronPet
@testable import IronPetCore
import IronPetKit

@MainActor
final class DictationTests: XCTestCase {
    private final class FakeField: DictationField {
        var accepts: Bool
        private(set) var inserted: [String] = []
        var frame: CGRect? { CGRect(x: 100, y: 100, width: 200, height: 30) }
        init(accepts: Bool = true) { self.accepts = accepts }
        func insert(_ text: String) -> Bool {
            guard accepts else { return false }
            inserted.append(text)
            return true
        }
    }

    private struct FakeFocus: DictationFocusReader {
        var focus: DictationFocus
        func current() -> DictationFocus { focus }
    }

    private var board: NSPasteboard!

    override func setUp() {
        board = NSPasteboard(name: NSPasteboard.Name("ironpet-test-\(UUID().uuidString)"))
        board.clearContents()
        board.setString("before", forType: .string)
    }

    override func tearDown() { board.releaseGlobally() }

    private func delivery(_ focus: DictationFocus, paste: @escaping () -> Bool = { true }) -> DictationDelivery {
        DictationDelivery(focus: FakeFocus(focus: focus), board: board, sendPaste: paste, settle: {})
    }

    // MARK: S1

    func testTranscriptGoesIntoTheFocusedFieldAndTheClipboardIsUntouched() async {
        let field = FakeField()
        let outcome = await delivery(.field(field)).deliver("hello world")
        XCTAssertEqual(outcome, .inserted)
        XCTAssertEqual(field.inserted, ["hello world"])
        XCTAssertEqual(board.string(forType: .string), "before")
    }

    func testRecordedClipIsTranscribedAndInsertedAtTheCursor() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.respond = { _ in (200, Data(#"{"text":"typed by voice"}"#.utf8), nil) }
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let samples = (0..<(WAV.sampleRate * 2)).map { Int16(sin(Double($0) * 2 * .pi * 440 / Double(WAV.sampleRate)) * 3000) }
        try WAV.encode(samples).write(to: clip)
        defer { try? FileManager.default.removeItem(at: clip) }
        let field = FakeField()
        let controller = DictationController(delivery: delivery(.field(field)))
        controller.voice.isEnabled = { true }
        controller.voice.makeTranscriber = {
            Transcriber(baseURL: "http://stub.test/v1", model: "m", apiKey: nil, session: URLSession(configuration: configuration))
        }
        defer { controller.cancel() }

        controller.shortcutPressed(.file(clip))
        try await waitFor { controller.voice.phase == .recording }
        try await Task.sleep(for: .milliseconds(400))
        controller.shortcutPressed(.file(clip)) // the second press stops
        try await waitFor { !field.inserted.isEmpty }
        XCTAssertEqual(field.inserted, ["typed by voice"])
        XCTAssertEqual(controller.voice.phase, .idle)
    }

    // MARK: S2

    func testCancelInsertsNothingAndSendsNoAudio() async throws {
        var transcriptions = 0
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try WAV.encode((0..<(WAV.sampleRate * 2)).map { _ in Int16(1000) }).write(to: clip)
        defer { try? FileManager.default.removeItem(at: clip) }
        let field = FakeField()
        let controller = DictationController(delivery: delivery(.field(field)))
        controller.voice.isEnabled = { true }
        controller.voice.makeTranscriber = {
            transcriptions += 1
            return Transcriber(baseURL: "http://127.0.0.1:9/v1", model: "none", apiKey: nil, timeout: 1)
        }
        controller.shortcutPressed(.file(clip))
        try await waitFor { controller.voice.phase == .recording }
        try await Task.sleep(for: .milliseconds(400))
        controller.voice.cancel()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.voice.phase, .idle)
        XCTAssertEqual(transcriptions, 0)
        XCTAssertTrue(field.inserted.isEmpty)
        XCTAssertNil(controller.lastOutcome)
        XCTAssertEqual(board.string(forType: .string), "before")
    }

    // MARK: S3

    func testPasteFallbackPastesAndRestoresTheClipboard() async throws {
        let item = NSPasteboardItem()
        item.setString("before", forType: .string)
        item.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("dev.ironpet.test"))
        board.clearContents()
        board.writeObjects([item])
        var seenWhenPasting: String?
        let outcome = await delivery(.field(FakeField(accepts: false))) {
            seenWhenPasting = self.board.string(forType: .string)
            return true
        }.deliver("dictated")
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(seenWhenPasting, "dictated")
        XCTAssertEqual(board.string(forType: .string), "before")
        XCTAssertEqual(board.data(forType: NSPasteboard.PasteboardType("dev.ironpet.test")), Data([1, 2, 3]))
    }

    func testClipboardIsLeftAloneWhenSomethingElseWroteToItDuringThePaste() async {
        let outcome = await DictationDelivery(focus: FakeFocus(focus: .field(FakeField(accepts: false))), board: board,
                                              sendPaste: { true }, settle: {
            self.board.clearContents()
            self.board.setString("user copied this", forType: .string)
        }).deliver("dictated")
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(board.string(forType: .string), "user copied this")
    }

    func testBlockedPasteKeepsTheTextOnTheClipboard() async {
        let outcome = await delivery(.field(FakeField(accepts: false)), paste: { false }).deliver("dictated")
        XCTAssertEqual(outcome, .copied(.pasteBlocked))
        XCTAssertEqual(board.string(forType: .string), "dictated")
    }

    // MARK: S4

    func testSecureFieldNeverGetsTextAndTheTranscriptGoesToTheClipboard() async {
        var pasted = false
        let outcome = await delivery(.secure, paste: { pasted = true; return true }).deliver("my password")
        XCTAssertEqual(outcome, .copied(.secureField))
        XCTAssertFalse(pasted)
        XCTAssertEqual(board.string(forType: .string), "my password")
        XCTAssertNotNil(DictationController.notice(for: outcome))
    }

    func testNoFocusedFieldCopiesWithANotice() async {
        let outcome = await delivery(.none).deliver("loose words")
        XCTAssertEqual(outcome, .copied(.noField))
        XCTAssertEqual(board.string(forType: .string), "loose words")
        XCTAssertEqual(DictationController.notice(for: outcome), "No text field has focus. The text is on your clipboard.")
    }

    func testMissingAccessibilityAccessCopiesWithANotice() async {
        let outcome = await delivery(.noAccess).deliver("words")
        XCTAssertEqual(outcome, .copied(.noAccess))
        XCTAssertEqual(board.string(forType: .string), "words")
        XCTAssertNotNil(DictationController.notice(for: outcome))
    }

    func testInsertedAndPastedNeedNoNotice() {
        XCTAssertNil(DictationController.notice(for: .inserted))
        XCTAssertNil(DictationController.notice(for: .pasted))
    }

    // MARK: S5

    func testDefaultShortcutIsControlOptionSpace() throws {
        let config = Config()
        XCTAssertEqual(config.hotkeys.dictation, "ctrl+opt+space")
        let shortcut = try XCTUnwrap(Shortcut(config.hotkeys.dictation))
        XCTAssertEqual(shortcut, Shortcut(keyCode: 49, modifiers: 0x1000 | 0x0800))
        XCTAssertEqual(shortcut.display, "⌃⌥Space")
    }

    func testShortcutCanBeChangedAndClearedAndTheRegisteredKeyFollows() throws {
        var config = Config()
        config.voice.enabled = true
        XCTAssertEqual(DictationController.hotkey(in: config), "ctrl+opt+space")
        config.hotkeys.dictation = "cmd+opt+d"
        XCTAssertEqual(DictationController.hotkey(in: config), "cmd+opt+d")
        config.hotkeys.dictation = ""
        XCTAssertNil(DictationController.hotkey(in: config))
        config.hotkeys.dictation = "ctrl+opt+space"
        config.voice.enabled = false
        XCTAssertNil(DictationController.hotkey(in: config), "off with voice notes")
    }

    func testShortcutSurvivesSaveAndLoadAndOldConfigsGetTheDefault() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try #"{"hotkeys":{"chat":"cmd+opt+h"}}"#.write(to: file, atomically: true, encoding: .utf8)
        var config = Config.load(from: file).config
        XCTAssertEqual(config.hotkeys.dictation, "ctrl+opt+space")
        config.hotkeys.dictation = ""
        try config.save(to: file)
        XCTAssertEqual(Config.load(from: file).config.hotkeys.dictation, "")
    }

    // MARK: Bar placement

    func testBarSitsAboveTheFieldOrBelowWhenThereIsNoRoomAndTopCentreWithoutAField() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = DictationPill.size
        let above = DictationBarPanel.origin(for: CGRect(x: 400, y: 300, width: 200, height: 30), in: area)
        XCTAssertEqual(above.y, 338)
        XCTAssertEqual(above.x, 500 - size.width / 2)
        let below = DictationBarPanel.origin(for: CGRect(x: 400, y: 770, width: 200, height: 30), in: area)
        XCTAssertEqual(below.y, 770 - size.height - 8)
        let top = DictationBarPanel.origin(for: nil, in: area)
        XCTAssertEqual(top, CGPoint(x: 500 - size.width / 2, y: 800 - size.height - 12))
    }

    private func waitFor(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
}

@MainActor
final class DotMeterDriverTests: XCTestCase {
    func testHiddenMeterNeverDraws() {
        let levels = LevelBuffer()
        let driver = DotMeterDriver(levels: levels, slow: false)
        for step in 0..<40 {
            levels.record(Float(step % 5) / 5)
            levels.tick()
            driver.poll()
        }
        XCTAssertEqual(driver.drawCount, 0)
    }

    func testSilenceDoesNotDraw() {
        let levels = LevelBuffer()
        let driver = DotMeterDriver(levels: levels, slow: false)
        driver.setVisible(true)
        driver.poll()
        let first = driver.drawCount
        for _ in 0..<200 {
            levels.tick()
            driver.poll()
        }
        XCTAssertEqual(driver.drawCount, first)
        driver.setVisible(false)
    }

    func testChangingLevelsDrawAtMostTwentyTimesASecond() {
        // A fixed stream of changing levels: 25 ticks a second for 10 s, polled at the live interval.
        let levels = LevelBuffer()
        let driver = DotMeterDriver(levels: levels, slow: false)
        driver.setVisible(true)
        let seconds = 10.0
        var now = 0.0
        var nextTick = 0.0
        var ticks = 0
        while now < seconds {
            if now >= nextTick {
                levels.record(ticks.isMultiple(of: 2) ? 0.9 : 0.2)
                levels.tick()
                ticks += 1
                nextTick += LevelBuffer.tickInterval
            }
            driver.poll()
            now += DotMeterDriver.liveInterval
        }
        XCTAssertGreaterThan(driver.drawCount, 0)
        XCTAssertLessThanOrEqual(Double(driver.drawCount) / seconds, 20.5)
        driver.setVisible(false)
    }

    func testReduceMotionAndPausedUseSlowPath() {
        XCTAssertEqual(DotMeterDriver.interval(slow: true, quietFor: 0), DotMeterDriver.slowInterval)
        XCTAssertEqual(DotMeterDriver.interval(slow: false, quietFor: 10), DotMeterDriver.slowInterval)
        XCTAssertEqual(DotMeterDriver.interval(slow: false, quietFor: 0), DotMeterDriver.liveInterval)
        XCTAssertLessThan(DotMeterDriver.liveInterval, DotMeterDriver.slowInterval)
    }
}
