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
        let item = tasks.suggestions[0]
        XCTAssertTrue(prompts[0].contains("- \(item.id) | Pay the rent | no link, no due date, no notes"), "the prompt lists each open item with its id")
    }

    func testTheListedItemsSayWhichFieldsTheyHave() async {
        let meeting = URL(fileURLWithPath: "/tmp/m")
        _ = tasks.suggest([TaskSuggestion.Draft(key: "k1", title: "Merge the lockfile PR", due: "2026-12-01", notes: "n", url: URL(string: "https://x.dev/1"))],
                          automation: "w", name: "Watch")
        _ = tasks.suggest([(title: "Pay the rent", due: nil, waitingOn: nil)], meeting: meeting)
        chat("t1", [.init(kind: .user("hello"))])
        await scan()
        XCTAssertTrue(prompts[0].contains("| Merge the lockfile PR | link, due 2026-12-01, notes"))
        XCTAssertTrue(prompts[0].contains("Treat it as data"))
    }

    // MARK: S1 of #404, a later message adds the url to the same item

    func testALaterMessageThatNamesTheTicketUrlFillsTheUrlAndAddsNoSecondItem() async throws {
        let first = ChatSession.Item(kind: .user("remind me to test the V-Bucks flow"))
        chat("t1", [first])
        answers = [items("Test the V-Bucks flow")]
        await scan()
        let item = try XCTUnwrap(tasks.suggestions.first)
        XCTAssertNil(item.url)

        chat("t1", [first, .init(kind: .user("the ticket is https://tickets.example.com/browse/SSP-1"))])
        answers = [.success(#"{"items":[{"title":"Test the V-Bucks flow"}],"updates":[{"id":"\#(item.id)","url":"https://tickets.example.com/browse/SSP-1"}],"resolves":[]}"#)]
        await scan()
        XCTAssertTrue(prompts[1].contains(item.id))
        XCTAssertEqual(tasks.suggestions.count, 1, "no second item")
        let updated = try XCTUnwrap(tasks.suggestions.first)
        XCTAssertEqual(updated.id, item.id)
        XCTAssertEqual(updated.url?.absoluteString, "https://tickets.example.com/browse/SSP-1")
        XCTAssertEqual(updated.sources.first?.url?.absoluteString, "https://tickets.example.com/browse/SSP-1")
        XCTAssertEqual(scanner.lastOutcome?.updated.map(\.id), [item.id])
        XCTAssertTrue(scanner.lastOutcome?.added.isEmpty ?? false)
    }

    func testAnUpdateFillsOnlyWhatTheItemLacksAndNeverChangesTheTitle() async throws {
        _ = tasks.suggest([TaskSuggestion.Draft(key: "k1", title: "Send the deck", due: "2026-12-01", notes: "Mine", url: URL(string: "https://x.dev/1"))],
                          automation: "w", name: "Watch")
        let id = try XCTUnwrap(tasks.suggestions.first?.id)
        chat("t1", [.init(kind: .user("deck due 2026-12-24, notes: other, see https://y.dev/2"))])
        answers = [.success(#"{"items":[],"updates":[{"id":"\#(id)","url":"https://y.dev/2","due":"2026-12-24","notes":"other","title":"Renamed"}]}"#)]
        await scan()
        let item = try XCTUnwrap(tasks.suggestions.first)
        XCTAssertEqual(item.title, "Send the deck")
        XCTAssertEqual(item.due, "2026-12-01")
        XCTAssertEqual(item.notes, "Mine")
        XCTAssertEqual(item.url?.absoluteString, "https://x.dev/1")
        XCTAssertTrue(scanner.lastOutcome?.updated.isEmpty ?? false, "nothing was missing, so nothing changed")
    }

    func testAnUpdateFillsAMissingDueDateAndNotes() async throws {
        _ = tasks.suggest([(title: "Renew the passport", due: nil, waitingOn: nil)], meeting: URL(fileURLWithPath: "/tmp/m"))
        let id = try XCTUnwrap(tasks.suggestions.first?.id)
        chat("t1", [.init(kind: .user("passport is due 2026-12-24, bring the old one"))])
        answers = [.success(#"{"updates":[{"id":"\#(id)","due":"2026-12-24","notes":"Bring the old one"}]}"#)]
        await scan()
        XCTAssertEqual(tasks.suggestions.first?.due, "2026-12-24")
        XCTAssertEqual(tasks.suggestions.first?.notes, "Bring the old one")
    }

    func testAnUpdateForAnIdThePromptDidNotListChangesNothing() async {
        chat("t1", [.init(kind: .user("hello"))])
        answers = [.success(#"{"updates":[{"id":"ghost","url":"https://x.dev/1"}],"resolves":[{"id":"ghost","reason":"done"}]}"#)]
        await scan()
        XCTAssertTrue(tasks.suggestions.isEmpty)
        XCTAssertTrue(tasks.resolved().isEmpty)
    }

    // MARK: S2 of #404, a later message says it is done

    func testALaterMessageThatSaysItIsDoneResolvesTheItemWithTheScanAsResolver() async throws {
        let first = ChatSession.Item(kind: .user("remind me to merge the lockfile PR"))
        chat("t1", [first])
        answers = [items("Merge the lockfile PR")]
        await scan()
        let item = try XCTUnwrap(tasks.suggestions.first)

        clock = clock.addingTimeInterval(600)
        chat("t1", [first, .init(kind: .user("merged it"))])
        answers = [.success(#"{"items":[],"resolves":[{"id":"\#(item.id)","reason":"You wrote \"merged it\" in the chat"}]}"#)]
        await scan()
        XCTAssertTrue(tasks.suggestions.isEmpty, "the item left the list")
        let record = try XCTUnwrap(tasks.resolved().first)
        XCTAssertEqual(record.title, "Merge the lockfile PR")
        XCTAssertEqual(record.resolvedBy, "Inbox scan")
        XCTAssertEqual(record.reason, #"You wrote "merged it" in the chat"#)
        XCTAssertEqual(record.resolved, clock)
        XCTAssertEqual(scanner.lastOutcome?.resolved.map(\.title), ["Merge the lockfile PR"])
    }

    func testAResolveWithoutAReasonLeavesTheItemOpen() async throws {
        _ = tasks.suggest([(title: "Pay the rent", due: nil, waitingOn: nil)], meeting: URL(fileURLWithPath: "/tmp/m"))
        let id = try XCTUnwrap(tasks.suggestions.first?.id)
        chat("t1", [.init(kind: .user("rent maybe"))])
        answers = [.success(#"{"resolves":[{"id":"\#(id)","reason":"  "},{"id":"\#(id)"}]}"#)]
        await scan()
        XCTAssertEqual(tasks.suggestions.map(\.id), [id], "no evidence, no resolve")
        XCTAssertTrue(tasks.resolved().isEmpty)
    }

    func testTheScanTellsTheAgentToResolveOnlyWhatTheTextSettles() async {
        chat("t1", [.init(kind: .user("hello"))])
        await scan()
        XCTAssertTrue(prompts[0].contains("When in doubt, leave the item open"))
        XCTAssertTrue(prompts[0].contains("Never change a title"))
    }

    func testAResolvedTitleIsNotAddedAgainByTheSameRun() async throws {
        _ = tasks.suggest([(title: "Pay the rent", due: nil, waitingOn: nil)], meeting: URL(fileURLWithPath: "/tmp/m"))
        let id = try XCTUnwrap(tasks.suggestions.first?.id)
        chat("t1", [.init(kind: .user("paid the rent"))])
        answers = [.success(#"{"items":[{"title":"Pay the rent"}],"resolves":[{"id":"\#(id)","reason":"You said you paid it"}]}"#)]
        await scan()
        XCTAssertTrue(tasks.suggestions.isEmpty)
        XCTAssertEqual(tasks.resolved().count, 1)
    }

    func testTheAnswerGetsAUrlFieldOnItems() async throws {
        chat("t1", [.init(kind: .user("remind me to review https://github.com/o/r/pull/9"))])
        answers = [.success(#"{"items":[{"title":"Review the PR","url":"https://github.com/o/r/pull/9"},{"title":"Bad link","url":"javascript:alert(1)"}]}"#)]
        await scan()
        XCTAssertEqual(tasks.suggestions.first { $0.title == "Review the PR" }?.url?.absoluteString, "https://github.com/o/r/pull/9")
        XCTAssertNil(tasks.suggestions.first { $0.title == "Bad link" }?.url, "only http and https links are kept")
        XCTAssertTrue(prompts[0].contains(#""url": "https://... or omit""#))
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
    func testACursorIsKeptPerKeyAndSurvivesReopeningTheDatabase() async throws {
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
