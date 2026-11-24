import XCTest
@testable import IronPetCore

/// The hourly digest: what it reads, what it sends to which agent, what it saves, and the merge pass.
@MainActor
final class MemoryReflectorTests: XCTestCase {
    private var dir: URL!
    private var store: EntityMemoryStore!
    private var index: MemoryIndex!
    private var reflector: MemoryReflector!
    private var threads: [String: ChatThread] = [:]
    private var tasks: [TaskItem] = []
    private var captures: [StoredCapture] = []
    private var posted: [Signal] = []
    private var prompts: [String] = []
    /// Who read each prompt.
    private var readers: [MemoryReflector.Reader] = []
    /// Answers the fake agent gives, in order. Out of answers, it says there is nothing to keep.
    private var answers: [Result<String, MemoryReflector.RunError>] = []
    private var config = Config.Memory()
    private var clock = Date(timeIntervalSince1970: 1_795_000_000)
    private var workspace: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-reflector-\(UUID().uuidString)")
        workspace = dir.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        index = MemoryIndex(database: try Database(path: nil, migrations: AppMigrations.all))
        store = EntityMemoryStore(database: index.database, index: index)
        store.now = { [unowned self] in clock }
        reflector = MemoryReflector(store: store, index: index) { [unowned self] prompt, reader in
            prompts.append(prompt)
            readers.append(reader)
            return answers.isEmpty ? .success(#"{"notes":[],"links":[]}"#) : answers.removeFirst()
        }
        reflector.config = { [unowned self] in config }
        reflector.now = { [unowned self] in clock }
        reflector.threads = { [unowned self] in threads[$0] }
        reflector.recentThreads = { [unowned self] in threads.values.sorted { $0.updatedAt > $1.updatedAt } }
        reflector.tasks = { [unowned self] in tasks }
        reflector.captures = { [unowned self] in captures }
        reflector.post = { [unowned self] in posted.append($0) }
        reflector.digestAgent = { "claude" }
        reflector.petName = { "Ghost" }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func chat(_ id: String, _ items: [ChatSession.Item], updated: Date? = nil, automation: String? = nil, agent: String = "claude") -> ChatThread {
        let thread = ChatThread(id: id, title: "t", workspace: workspace.path, updatedAt: updated ?? clock, items: items, agent: agent,
                                automation: automation)
        threads[id] = thread
        return thread
    }

    private func notes(_ json: String) -> Result<String, MemoryReflector.RunError> { .success(json) }

    private func task(_ id: String, _ title: String, notes: String = "") -> TaskItem {
        TaskItem(id: id, title: title, notes: notes, status: .backlog, source: .user, links: [], created: clock, updated: clock)
    }

    private func waitIdle() async {
        for _ in 0..<200 where reflector.running != nil || !reflector.queue.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// Runs one digest and waits for everything it queued.
    private func digest() async {
        reflector.digest()
        await waitIdle()
    }

    private func claims(_ entity: String) -> [String] {
        store.claims(of: entity).map(\.text)
    }

    // MARK: Chats

    func testTheDigestReadsUnreadChatsAndSavesTheNotes() async {
        chat("t1", [.init(kind: .user("I always use pnpm, never npm")), .init(kind: .assistant("Noted."))])
        answers = [notes(#"{"notes":[{"scope":"me","text":"Prefers pnpm over npm.","replaces":[]}],"links":[]}"#)]
        await digest()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("User: I always use pnpm, never npm"))
        XCTAssertTrue(prompts[0].contains("Ghost: Noted."))
        XCTAssertEqual(claims("me"), ["Prefers pnpm over npm."])
        XCTAssertEqual(store.claims(of: "me").first?.sources.last, "chat:t1")
        XCTAssertEqual(reflector.lastOutcome?.saved, ["Prefers pnpm over npm."])
    }

    func testOnlyMessagesSinceTheLastDigestAreSentAndNothingNewSendsNothing() async {
        chat("t1", [.init(kind: .user("first")), .init(kind: .assistant("ok"))])
        await digest()
        XCTAssertEqual(prompts.count, 1)
        await digest()
        XCTAssertEqual(prompts.count, 1, "nothing new since the last digest sends nothing")
        threads["t1"]?.items.append(.init(kind: .user("second")))
        await digest()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("second"))
        XCTAssertFalse(prompts[1].contains("first"))
    }

    func testAutomationTurnsInAChatAreLeftOut() {
        let items: [ChatSession.Item] = [.init(kind: .user("hidden automation prompt"), origin: ChatSession.automationOrigin),
                                         .init(kind: .assistant("hidden reply")), .init(kind: .user("I use zsh"))]
        chat("t1", items)
        XCTAssertEqual(reflector.unread(in: threads["t1"]!).map(\.text), ["I use zsh"])
    }

    func testAFailedRunKeepsTheMessagesForTheNextDigest() async {
        chat("t1", [.init(kind: .user("I use zsh"))])
        answers = [.failure(MemoryReflector.RunError("agent missing"))]
        await digest()
        XCTAssertEqual(reflector.lastOutcome?.error, "agent missing")
        await digest()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("I use zsh"), "the messages are read again")
    }

    func testTheDigestRunsOnlyWhenTheDigestIntervalHasPassed() async {
        chat("t1", [.init(kind: .user("I use zsh"))])
        reflector.tick()
        await waitIdle()
        XCTAssertEqual(prompts.count, 1, "the first tick runs the digest")
        threads["t1"]?.items.append(.init(kind: .user("I use fish")))
        clock += 59 * 60
        reflector.tick()
        await waitIdle()
        XCTAssertEqual(prompts.count, 1, "not yet an hour")
        clock += 60
        reflector.tick()
        await waitIdle()
        XCTAssertEqual(prompts.count, 2)
    }

    func testWithLearningOffNothingIsRead() async {
        config.reflect = false
        chat("t1", [.init(kind: .user("I use zsh"))])
        await digest()
        XCTAssertTrue(prompts.isEmpty)
    }

    func testFirstLaunchMarksEarlierChatsAsReadBeforeAnyDigest() async {
        chat("old", [.init(kind: .user("said long ago"))], updated: clock.addingTimeInterval(-10 * 86_400))
        reflector.seedIfNeeded()
        await digest()
        XCTAssertTrue(prompts.isEmpty, "a chat from before memory was set up is not read")
    }

    func testEachChatIsReadByItsOwnAgent() async {
        chat("c1", [.init(kind: .user("I use zsh"))], agent: "cursor")
        chat("c2", [.init(kind: .user("I use fish"))], agent: "claude")
        await digest()
        XCTAssertEqual(readers.sorted { $0.agent < $1.agent }, [.init(agent: "claude", model: "haiku"), .init(agent: "cursor", model: nil)])
    }

    func testAPickedAgentOnlyReadsItsOwnChats() async {
        config.reflectAgent = "claude"
        chat("c1", [.init(kind: .user("I use zsh"))], agent: "cursor")
        chat("c2", [.init(kind: .user("I use fish"))], agent: "claude")
        await digest()
        XCTAssertEqual(readers, [.init(agent: "claude", model: "haiku")], "text the picked agent never had is not sent to it")
    }

    // MARK: Outside text

    func testOutsideTextCannotWriteMeButCanWritePeople() async throws {
        let folder = dir.appendingPathComponent("2026-11-18-1100")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Ana decided. Vera is the owner.".write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        answers = [notes(#"{"notes":[{"scope":"me","text":"Owns the payments team."},{"scope":"people","person":"Ana","text":"Leads payments."}],"links":[]}"#)]
        reflector.meetingSummaryWritten(folder, agent: "claude")
        await digest()
        XCTAssertEqual(claims("me"), [], "a meeting summary may not write me.md")
        XCTAssertEqual(store.claims(of: EntityMatcher.personID("Ana")).map(\.text), ["Leads payments."])
        XCTAssertEqual(reflector.lastOutcome?.dropped.count, 1)
    }

    func testAnAutomationAnswerIsOutsideTextAndReadAtOnce() async {
        config.reflect = true
        reflector.automationFinished(id: "a", name: "A", answer: "Ana is out", agent: "codex")
        await waitIdle()
        XCTAssertEqual(readers, [.init(agent: "codex", model: nil)])
        XCTAssertFalse(prompts[0].contains("<notes file=\"me.md\">"), "outside text is sent without the notes")
    }

    // MARK: Tasks and the screen

    func testTasksAreReadOnlyWhenNewOrChanged() async {
        tasks = [task("1", "Renew the domain")]
        answers = [notes(#"{"notes":[{"scope":"project","text":"Domain renewal is yearly."}],"links":[]}"#)]
        await digest()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("- Renew the domain (backlog)"))
        await digest()
        XCTAssertEqual(prompts.count, 1, "an unchanged task is not read again")
        tasks = [task("1", "Renew the domain", notes: "Due in March")]
        await digest()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("Due in March"))
    }

    func testScreenTextIsOffByDefault() async {
        captures = [StoredCapture(id: 1, at: clock, app: "com.apple.Safari", appName: "Safari", window: "Docs", trigger: "timer", text: "Ana wrote the report")]
        await digest()
        XCTAssertTrue(prompts.isEmpty)
    }

    func testWithLearnFromScreenOnTheNewCapturesAreReadOnce() async {
        config.learnFromScreen = true
        captures = [StoredCapture(id: 2, at: clock, app: "a", appName: "Safari", window: "Docs", trigger: "timer", text: "Ana wrote the report"),
                    StoredCapture(id: 1, at: clock, app: "a", appName: "Safari", window: "Docs", trigger: "timer", text: "older")]
        await digest()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("Ana wrote the report"))
        await digest()
        XCTAssertEqual(prompts.count, 1, "the captures are read once")
    }

    // MARK: Links and names

    func testLinksAreWrittenAfterTheNotesBetweenKnownPages() async {
        chat("t1", [.init(kind: .user("Ana runs payments"))])
        answers = [notes(#"{"notes":[{"scope":"people","person":"Ana","text":"Runs payments."}],"links":[{"from":"Ana","type":"works_on","to":"About me"}]}"#)]
        await digest()
        let links = store.links("Ana", type: nil)
        XCTAssertEqual(try links.get().map(\.type), ["works_on"], "a person the same pass named has a page to link")
    }

    func testAnAmbiguousNameAsksInsteadOfGuessing() async {
        chat("t1", [.init(kind: .user("setup"))])
        _ = try? store.remember("Leads payments", scope: .people, person: "Ana Silva", source: "chat:a").get()
        _ = try? store.remember("Reviews PRs", scope: .people, person: "Ana Lopez", source: "chat:a").get()
        answers = [notes(#"{"notes":[{"scope":"people","person":"Ana","text":"Prefers async updates."}],"links":[]}"#)]
        await digest()
        XCTAssertTrue(store.claims(of: EntityMatcher.personID("Ana")).isEmpty, "nothing is written to a guessed page")
        XCTAssertEqual(posted.map(\.id), ["memory-ambiguous:ana"])
        XCTAssertEqual(posted.first?.title, "Which Ana?")
        XCTAssertNotNil(posted.first?.ask)
    }

    // MARK: Merge pass

    func testAPageOverTheLimitIsMergedButPinnedFactsAreNot() async throws {
        config.maxClaimsPerEntity = 10
        for n in 1...12 { _ = try me("Fact number \(n)") }
        let oldest = try XCTUnwrap(store.claims(of: "me").last)
        _ = store.setPinned(oldest.id, true)
        let next = try XCTUnwrap(store.claims(of: "me").last(where: { !$0.pinned }))
        let other = try XCTUnwrap(store.claims(of: "me").dropLast().last(where: { !$0.pinned && $0.id != next.id }))
        answers = [notes(#"{"merges":[{"ids":["\#(next.ref)","\#(other.ref)"],"text":"Merged fact."}]}"#)]
        await digest()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("\(next.id): Fact number"), "the oldest unpinned facts are shown")
        XCTAssertTrue(claims("me").contains("Merged fact."))
        XCTAssertEqual(store.claims(of: "me").count, 11)
        XCTAssertTrue(store.claims(of: "me").contains { $0.pinned && $0.id == oldest.id }, "a pinned fact is never merged")
    }

    func testAMergeNamingAPinnedClaimChangesNothing() async throws {
        config.maxClaimsPerEntity = 10
        for n in 1...12 { _ = try me("Fact number \(n)") }
        let pinned = try XCTUnwrap(store.claims(of: "me").last)
        _ = store.setPinned(pinned.id, true)
        let other = try XCTUnwrap(store.claims(of: "me").dropLast().last)
        answers = [notes(#"{"merges":[{"ids":["\#(pinned.ref)","\#(other.ref)"],"text":"Should not be saved."}]}"#)]
        await digest()
        XCTAssertFalse(claims("me").contains("Should not be saved."))
        XCTAssertEqual(store.claims(of: "me").count, 12)
    }

    func testAPageUnderTheLimitIsNotMerged() async throws {
        _ = try me("One fact")
        await digest()
        XCTAssertTrue(prompts.isEmpty)
    }

    // MARK: Parsing and the run

    func testParseReadsFencedJSONAndSkipsBadEntries() async {
        let answer = "Here:\n```json\n{\"notes\":[{\"scope\":\"ME\",\"text\":\"a\"},{\"scope\":\"world\",\"text\":\"b\"},{\"text\":\"c\"}]}\n```"
        XCTAssertEqual(MemoryReflector.parse(answer), [.init(scope: .me, text: "a", person: nil, replaces: [])])
        XCTAssertNil(MemoryReflector.parse("no notes today"))
    }

    func testParseLinksKeepsOnlyNamedPairsWithAVerb() {
        let answer = #"{"notes":[],"links":[{"from":"Ana","type":"Works_On","to":"ironpet"},{"from":"Ana","type":"bad type!","to":"x"},{"from":"","type":"uses","to":"x"}]}"#
        let links = MemoryReflector.parseLinks(answer)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.type, "works_on")
    }

    func testParseMergesNeedsTheMergesObject() {
        XCTAssertEqual(MemoryReflector.parseMerges(#"{"merges":[{"ids":["claim_3f9a2c","claim_7b1e04"],"text":"Joined."}]}"#)?.first?.ids,
                       ["claim_3f9a2c", "claim_7b1e04"])
        XCTAssertNil(MemoryReflector.parseMerges(#"{"notes":[]}"#))
    }

    func testForgetEverythingDropsQueuedJobsAndTheRunSavesNothing() async {
        chat("t1", [.init(kind: .user("I use zsh"))])
        reflector.digest()
        reflector.cancelAll()
        await waitIdle()
        XCTAssertTrue(store.claims(of: "me").isEmpty)
    }

    func testReflectNowWaitsForItsOutcome() async {
        chat("t1", [.init(kind: .user("I use zsh"))])
        let outcome = await reflector.reflectNow(.thread("t1"))
        XCTAssertEqual(outcome.job, .thread("t1"))
        XCTAssertEqual(prompts.count, 1)
    }

    func testTheDigestsPromptNamesTheLinksItWants() async {
        chat("t1", [.init(kind: .user("I use zsh"))])
        await digest()
        XCTAssertTrue(prompts[0].contains("\"links\""))
    }

    private func me(_ text: String) throws -> MemoryNote {
        try store.replace([], with: text, scope: .me, person: nil, project: nil, source: "chat:x").get()
    }
}
