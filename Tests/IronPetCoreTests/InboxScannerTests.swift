import XCTest
@testable import IronPetCore

/// The inbox scan: what it reads, what it files, and when it runs.
@MainActor
final class InboxScannerTests: XCTestCase {
    private var tasks: TaskStore!
    private var scanner: InboxScanner!
    private var threads: [String: ChatThread] = [:]
    private var captures: [StoredCapture] = []
    private var prompts: [String] = []
    private var readers: [ReflectionReader] = []
    private var answers: [Result<String, ReflectionError>] = []
    private var config = Config.Tasks(inboxScan: true)
    private var clock = Date(timeIntervalSince1970: 1_795_000_000)

    override func setUp() async throws {
        tasks = TaskStore(database: try Database(path: nil, migrations: AppMigrations.all), now: { [unowned self] in clock })
        scanner = InboxScanner(store: tasks) { [unowned self] prompt, reader in
            prompts.append(prompt)
            readers.append(reader)
            return answers.isEmpty ? .success(#"{"items":[]}"#) : answers.removeFirst()
        }
        scanner.config = { [unowned self] in config }
        scanner.now = { [unowned self] in clock }
        scanner.threads = { [unowned self] in threads[$0] }
        scanner.recentThreads = { [unowned self] in threads.values.sorted { $0.updatedAt > $1.updatedAt } }
        scanner.captures = { [unowned self] in captures }
        scanner.digestAgent = { "claude" }
        scanner.petName = { "Ghost" }
    }

    private func chat(_ id: String, _ items: [ChatSession.Item], automation: String? = nil, agent: String = "claude") {
        threads[id] = ChatThread(id: id, title: "t", workspace: "/tmp", updatedAt: clock, items: items, agent: agent, automation: automation)
    }

    private func items(_ titles: String...) -> Result<String, ReflectionError> {
        let list = titles.map { #"{"title":"\#($0)"}"# }.joined(separator: ",")
        return .success(#"{"items":[\#(list)]}"#)
    }

    private func waitIdle() async {
        for _ in 0..<200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            if scanner.lastOutcome != nil { break }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    private func scan() async {
        scanner.lastOutcomeReset()
        scanner.scan()
        await waitIdle()
    }

    private func screen(_ id: Int64, _ text: String) -> StoredCapture {
        StoredCapture(id: id, at: clock, app: "com.tinyspeck.slackmacgap", appName: "Slack", window: "general", trigger: "typingPause", text: text)
    }

    // MARK: S1

    func testAChatCommitmentReachesTheInboxAfterTheNextScan() async {
        chat("t1", [.init(kind: .user("remind me to renew the passport")), .init(kind: .assistant("Will do."))])
        answers = [items("Renew the passport")]
        await scan()
        XCTAssertTrue(prompts[0].contains("User: remind me to renew the passport"))
        XCTAssertEqual(tasks.suggestions.map(\.title), ["Renew the passport"])
        XCTAssertEqual(tasks.suggestions.first?.originKind, .chat)
        XCTAssertEqual(tasks.suggestions.first?.sources.first?.ref, "chat:t1")
        XCTAssertEqual(scanner.lastOutcome?.added.map(\.title), ["Renew the passport"])
    }

    func testAChatIsReadByItsOwnAgentAndOnlyNewMessagesAreSent() async {
        let first = ChatSession.Item(kind: .user("first")), reply = ChatSession.Item(kind: .assistant("ok"))
        chat("t1", [first, reply], agent: "codex")
        await scan()
        XCTAssertEqual(readers.map(\.agent), ["codex"])
        chat("t1", [first, reply, .init(kind: .user("second"))], agent: "codex")
        await scan()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("User: second"))
        XCTAssertFalse(prompts[1].contains("User: first"))
        await scan()
        XCTAssertEqual(prompts.count, 2, "nothing new sends nothing")
    }

    func testAnAutomationThreadIsNotRead() async {
        chat("a1", [.init(kind: .user("remind me to x"))], automation: "watch")
        await scan()
        XCTAssertTrue(prompts.isEmpty)
    }

    func testAFailedRunKeepsTheCursorSoTheNextScanReadsTheMessagesAgain() async {
        chat("t1", [.init(kind: .user("remind me to call Ana"))])
        answers = [.failure(ReflectionError("offline")), items("Call Ana")]
        await scan()
        XCTAssertEqual(scanner.lastOutcome?.error, "offline")
        XCTAssertTrue(tasks.suggestions.isEmpty)
        await scan()
        XCTAssertEqual(tasks.suggestions.map(\.title), ["Call Ana"])
    }

    func testTheRunFilesAtMostEightItems() async {
        chat("t1", [.init(kind: .user("lots"))])
        answers = [items("a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9", "a10")]
        await scan()
        XCTAssertEqual(tasks.suggestions.count, InboxScanner.maxItems)
    }

    func testTheInboxTitlesGoInThePromptSoTheAgentSkipsThem() async {
        _ = tasks.suggest([(title: "Pay the rent", due: nil, waitingOn: nil)], meeting: URL(fileURLWithPath: "/tmp/m"))
        chat("t1", [.init(kind: .user("hello"))])
        await scan()
        XCTAssertTrue(prompts[0].contains("- Pay the rent"))
    }

    // MARK: S2

    func testScreenTextIsReadOnlyWhenTheSwitchIsOn() async {
        captures = [screen(2, "I'll send the invoice by Friday")]
        config.inboxScanScreen = false
        await scan()
        XCTAssertTrue(prompts.isEmpty, "off: nothing is read")
        XCTAssertTrue(tasks.suggestions.isEmpty)

        config.inboxScanScreen = true
        answers = [items("Send the invoice by Friday")]
        await scan()
        XCTAssertTrue(prompts[0].contains("Slack · general: I'll send the invoice by Friday"))
        XCTAssertEqual(tasks.suggestions.map(\.title), ["Send the invoice by Friday"])
        XCTAssertEqual(tasks.suggestions.first?.originKind, .capture)
    }

    func testAScreenJobQueuedBeforeTheSwitchWentOffReadsNothing() async {
        captures = [screen(1, "I'll call Ana")]
        config.inboxScanScreen = true
        scanner.scan()
        config.inboxScanScreen = false
        await waitIdle()
        XCTAssertTrue(prompts.isEmpty)
    }

    func testOnlyCapturesAfterTheCursorAreSent() async {
        config.inboxScanScreen = true
        captures = [screen(1, "first text")]
        await scan()
        captures = [screen(2, "second text"), screen(1, "first text")]
        await scan()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("second text"))
        XCTAssertFalse(prompts[1].contains("first text"))
    }

    // MARK: S3 and S4

    func testTheSameCommitmentSeenTwiceIsOneItem() async {
        chat("t1", [.init(kind: .user("remind me to renew the passport"))])
        answers = [items("Renew the passport")]
        await scan()
        chat("t1", [.init(kind: .user("remind me to renew the passport")), .init(kind: .user("again: renew the passport"))])
        answers = [items("Renew the passport.")]
        await scan()
        XCTAssertEqual(tasks.suggestions.count, 1)
        XCTAssertEqual(scanner.lastOutcome?.added, [])
    }

    func testTheSameCommitmentFromChatAndScreenIsOneItem() async {
        chat("t1", [.init(kind: .user("remind me to renew the passport"))])
        answers = [items("Renew the passport")]
        await scan()
        config.inboxScanScreen = true
        captures = [screen(1, "renew the passport")]
        answers = [items("renew the passport")]
        await scan()
        XCTAssertEqual(tasks.suggestions.count, 1)
    }

    func testARemovedItemDoesNotComeBack() async throws {
        chat("t1", [.init(kind: .user("remind me to renew the passport"))])
        answers = [items("Renew the passport")]
        await scan()
        try tasks.remove(try XCTUnwrap(tasks.suggestions.first).id)
        XCTAssertTrue(tasks.suggestions.isEmpty)
        chat("t1", [.init(kind: .user("remind me to renew the passport")), .init(kind: .user("still need to renew the passport"))])
        answers = [items("Renew the passport")]
        await scan()
        XCTAssertEqual(prompts.count, 2, "the scan read the new message")
        XCTAssertTrue(tasks.suggestions.isEmpty)
        XCTAssertEqual(scanner.lastOutcome?.added, [])
    }

    func testADoneItemDoesNotComeBack() async throws {
        chat("t1", [.init(kind: .user("remind me to pay rent"))])
        answers = [items("Pay rent")]
        await scan()
        try tasks.done(try XCTUnwrap(tasks.suggestions.first).id)
        chat("t1", [.init(kind: .user("remind me to pay rent")), .init(kind: .user("pay rent"))])
        answers = [items("Pay rent")]
        await scan()
        XCTAssertTrue(tasks.suggestions.isEmpty)
    }

    // MARK: S5

    func testWithTheScanOffNothingIsReadOrAddedWhenTheIntervalPasses() async {
        config.inboxScan = false
        chat("t1", [.init(kind: .user("remind me to renew the passport"))])
        answers = [items("Renew the passport")]
        scanner.tick()
        clock = clock.addingTimeInterval(24 * 3600)
        scanner.tick()
        await waitIdle()
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertTrue(tasks.suggestions.isEmpty)
    }

    func testTheSwitchTurnedOffWhileTheAgentRunsAddsNothing() async {
        chat("t1", [.init(kind: .user("remind me to renew the passport"))])
        scanner.runner = { [unowned self] _, _ in
            config.inboxScan = false
            return items("Renew the passport")
        }
        scanner.scan()
        await waitIdle()
        XCTAssertTrue(tasks.suggestions.isEmpty)
    }

    func testTickScansOnlyAfterTheInterval() async {
        config.inboxScanMinutes = 30
        chat("t1", [.init(kind: .user("one"))])
        scanner.tick()
        await waitIdle()
        XCTAssertEqual(prompts.count, 1, "the first tick scans")
        chat("t1", [.init(kind: .user("one")), .init(kind: .user("two"))])
        clock = clock.addingTimeInterval(10 * 60)
        scanner.tick()
        await waitIdle()
        XCTAssertEqual(prompts.count, 1, "ten minutes is too soon")
        clock = clock.addingTimeInterval(21 * 60)
        scanner.lastOutcomeReset()
        scanner.tick()
        await waitIdle()
        XCTAssertEqual(prompts.count, 2)
    }

    func testTheScanDoesNothingInTestMode() async {
        scanner.automatic = false
        chat("t1", [.init(kind: .user("one"))])
        scanner.tick()
        await waitIdle()
        XCTAssertTrue(prompts.isEmpty)
    }

    // MARK: Seeding and parsing

    func testSeedingMarksEarlierTextAsReadSoTurningTheScanOnDoesNotSendHistory() async {
        chat("t1", [.init(kind: .user("old message"))])
        captures = [screen(5, "old screen text")]
        config.inboxScanScreen = true
        scanner.seedIfNeeded()
        await scan()
        XCTAssertTrue(prompts.isEmpty)
        chat("t1", [.init(kind: .user("old message")), .init(kind: .user("new message"))])
        await scan()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("new message"))
    }

    func testParseDropsBadEntriesAndKeepsAValidDue() {
        let drafts = InboxScanner.parse("""
            Here you go:
            ```json
            {"items": [{"title": "Renew the passport", "due": "2026-12-01", "notes": "expires in March"},
                       {"title": "  "}, {"title": "Call Ana", "due": "next week"}]}
            ```
            """)
        XCTAssertEqual(drafts?.map(\.title), ["Renew the passport", "Call Ana"])
        XCTAssertEqual(drafts?.first?.due, "2026-12-01")
        XCTAssertNil(drafts?.last?.due)
        XCTAssertNil(InboxScanner.parse("nothing to add"))
    }

    func testTheIdOfAnItemFollowsItsWording() {
        let a = InboxScanner.parse(#"{"items":[{"title":"Renew the passport"}]}"#)?.first?.key
        let b = InboxScanner.parse(#"{"items":[{"title":"renew  the passport."}]}"#)?.first?.key
        XCTAssertEqual(a, b)
        XCTAssertNotNil(a)
    }

    func testTheScanIsOffByDefault() {
        let tasks = Config().tasks
        XCTAssertFalse(tasks.inboxScan)
        XCTAssertFalse(tasks.inboxScanScreen)
        XCTAssertTrue(tasks.inboxScanBubbles)
        XCTAssertEqual(tasks.inboxScanMinutes, 30)
    }
}

@MainActor
final class InboxScanCursorTests: XCTestCase {
    func testACursorIsKeptPerKeyAndSurvivesReopeningTheDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ironpet.db")
        let first = TaskStore(database: try Database(path: file, migrations: AppMigrations.all))
        XCTAssertNil(first.scanCursor("screen"))
        first.setScanCursor("screen", item: "7")
        first.setScanCursor("screen", item: "9")
        first.setScanCursor("t1", item: "abc")
        let second = TaskStore(database: try Database(path: file, migrations: AppMigrations.all))
        XCTAssertEqual(second.scanCursor("screen")?.item, "9")
        XCTAssertEqual(second.scanCursor("t1")?.item, "abc")
    }
}
