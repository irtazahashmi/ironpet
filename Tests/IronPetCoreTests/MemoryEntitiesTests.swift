import XCTest
@testable import IronPetCore

/// Notes land on the project, organization, topic or tool they are about, not on the repo the chat ran in, and the one-time re-sort
/// moves the notes that were already misfiled.
@MainActor
final class MemoryEntitiesTests: XCTestCase {
    private var dir: URL!
    private var store: EntityMemoryStore!
    private var index: MemoryIndex!
    private var reflector: MemoryReflector!
    private var threads: [String: ChatThread] = [:]
    private var prompts: [String] = []
    private var answers: [String] = []
    private var clock = Date(timeIntervalSince1970: 1_795_000_000)
    private var workspace: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-entities-\(UUID().uuidString)")
        workspace = dir.appendingPathComponent("borko")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        index = MemoryIndex(database: try Database(path: nil, migrations: AppMigrations.all))
        store = EntityMemoryStore(database: index.database, index: index)
        store.now = { [unowned self] in clock }
        reflector = MemoryReflector(store: store, index: index) { [unowned self] prompt, _ in
            prompts.append(prompt)
            return .success(answers.isEmpty ? #"{"notes":[],"links":[]}"# : answers.removeFirst())
        }
        reflector.config = { Config.Memory() }
        reflector.now = { [unowned self] in clock }
        reflector.threads = { [unowned self] in threads[$0] }
        reflector.recentThreads = { [unowned self] in threads.values.sorted { $0.updatedAt > $1.updatedAt } }
        reflector.digestAgent = { "claude" }
        reflector.petName = { "Ghost" }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var repo: ProjectKey { MemoryMCP.project(workspace)! }
    private var repoPage: String { "project:" + repo.key }

    private func chat(_ id: String, _ text: String) {
        threads[id] = ChatThread(id: id, title: "t", workspace: workspace.path, updatedAt: clock,
                                 items: [.init(kind: .user(text)), .init(kind: .assistant("Noted."))], agent: "claude", automation: nil)
    }

    private func digest() async {
        reflector.digest()
        for _ in 0..<200 where reflector.running != nil || !reflector.queue.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func texts(_ id: String) -> [String] { store.claims(of: id).map(\.text) }

    // MARK: S1, S2

    func testAFactAboutAnotherProductIsFiledUnderThatProjectNotTheChatsRepo() async {
        chat("t1", "In Lighthouse we ship every Friday")
        answers = [#"{"notes":[{"scope":"project","entity":"Lighthouse","text":"Ships every Friday.","replaces":[]}],"links":[]}"#]
        await digest()
        XCTAssertEqual(texts("project:lighthouse"), ["Ships every Friday."])
        XCTAssertEqual(store.entities().first { $0.id == "project:lighthouse" }?.type, .project)
        XCTAssertTrue(texts(repoPage).isEmpty, "the chat's repo is only a hint")
    }

    func testAProjectNoteWithoutAnEntityStaysOnTheChatsRepo() async {
        chat("t1", "Tests run with swift test")
        answers = [#"{"notes":[{"scope":"project","text":"Tests run with swift test.","replaces":[]}],"links":[]}"#]
        await digest()
        XCTAssertEqual(texts(repoPage), ["Tests run with swift test."])
    }

    func testACompanyAToolAndATopicAreFiledUnderTheirOwnTypes() async {
        chat("t1", "Acme pays late, Xcode keeps crashing, and we keep talking about invoicing")
        answers = [#"""
        {"notes":[{"scope":"org","entity":"Acme","text":"Pays invoices 30 days late.","replaces":[]},
        {"scope":"tool","entity":"Xcode","text":"Crashes on large asset catalogs.","replaces":[]},
        {"scope":"topic","entity":"Invoicing","text":"Moving to monthly invoices.","replaces":[]}],"links":[]}
        """#]
        await digest()
        XCTAssertEqual(texts("org:acme"), ["Pays invoices 30 days late."])
        XCTAssertEqual(texts("tool:xcode"), ["Crashes on large asset catalogs."])
        XCTAssertEqual(texts("topic:invoicing"), ["Moving to monthly invoices."])
        let types = Dictionary(uniqueKeysWithValues: store.entities().map { ($0.id, $0.type) })
        XCTAssertEqual(types["org:acme"], .org)
        XCTAssertEqual(types["tool:xcode"], .tool)
        XCTAssertEqual(types["topic:invoicing"], .topic)
    }

    // MARK: Entity types and work items (#367)

    func testTheTaxAdvisersFirmLandsOnAnOrganizationPageNotOnMe() async {
        chat("t1", "My tax adviser's firm, Weber & Partner, sends the return by March")
        answers = [#"{"notes":[{"scope":"org","entity":"Weber & Partner","text":"Tax adviser's firm; sends the return by March.","replaces":[]}],"links":[]}"#]
        await digest()
        XCTAssertEqual(texts("org:weber & partner"), ["Tax adviser's firm; sends the return by March."])
        XCTAssertEqual(store.entities().first { $0.name == "Weber & Partner" }?.type, .org)
        XCTAssertTrue(texts("me").isEmpty)
    }

    func testThePromptDefinesEachType() {
        let prompt = MemoryReflector.prompt(input: "x", kind: "a chat", notes: [], outside: false, hasProject: true, petName: "Ghost")
        for phrase in ["a person is a human", "company, employer, client, vendor, community or team", "a product, a codebase or a client engagement",
                       "software the user uses", "spans projects", "a language being learned", "legal or tax matter",
                       "never a page name", "state of a single task"] {
            XCTAssertTrue(prompt.contains(phrase), phrase)
        }
    }

    func testATicketKeyIsNeverAPageAndItsFactsGoOnTheProject() async {
        chat("t1", "SSP-10435 adds SSO to the portal")
        answers = [#"""
        {"notes":[{"scope":"project","entity":"SSP-10435","text":"SSP-10435 adds SSO to the portal.","replaces":[]},
        {"scope":"project","entity":"Self Service Portal","text":"SSP-10435 adds SSO login.","replaces":[]}],"links":[]}
        """#]
        await digest()
        XCTAssertEqual(texts("project:self service portal"), ["SSP-10435 adds SSO login."])
        XCTAssertFalse(store.entities().contains { $0.name.uppercased().contains("SSP-10435") })
        XCTAssertEqual(reflector.lastOutcome?.dropped.count, 1)
    }

    func testAnIssueNumberIsNeverAPageAndItsFactsGoOnTheIronPetProject() async {
        chat("t1", "Issue #304 in ironpet is about the dock icon")
        answers = [#"""
        {"notes":[{"scope":"project","entity":"#304","text":"#304 is about the dock icon.","replaces":[]},
        {"scope":"project","entity":"ironpet#304","text":"Is about the dock icon.","replaces":[]},
        {"scope":"project","entity":"IronPet","text":"Issue #304 covers the dock icon.","replaces":[]}],"links":[]}
        """#]
        await digest()
        XCTAssertEqual(texts("project:ironpet"), ["Issue #304 covers the dock icon."])
        XCTAssertEqual(store.entities().filter { $0.type == .project }.count, 1)
        XCTAssertEqual(reflector.lastOutcome?.dropped.count, 2)
    }

    func testLearningGermanLandsOnATopicPage() async {
        chat("t1", "I am learning German, B1 exam in June")
        answers = [#"{"notes":[{"scope":"topic","entity":"German","text":"Preparing for the B1 exam in June.","replaces":[]}],"links":[]}"#]
        await digest()
        XCTAssertEqual(texts("topic:german"), ["Preparing for the B1 exam in June."])
        XCTAssertEqual(store.entities().first { $0.id == "topic:german" }?.type, .topic)
    }

    func testTheStateOfOneTaskIsNotKept() async {
        chat("t1", "The PR is waiting for review")
        answers = [#"""
        {"notes":[{"scope":"project","entity":"IronPet","text":"PR #380 is waiting for review.","replaces":[]},
        {"scope":"project","entity":"IronPet","text":"The ticket is in progress.","replaces":[]},
        {"scope":"project","entity":"IronPet","text":"Pull request 12 was merged.","replaces":[]}],"links":[]}
        """#]
        await digest()
        XCTAssertTrue(texts("project:ironpet").isEmpty)
        XCTAssertEqual(reflector.lastOutcome?.dropped.count, 3)
    }

    func testALastingFactAboutPullRequestsIsKept() async {
        chat("t1", "We squash PRs")
        answers = [#"{"notes":[{"scope":"project","entity":"IronPet","text":"Pull requests are squash merged and need one approval.","replaces":[]}],"links":[]}"#]
        await digest()
        XCTAssertEqual(texts("project:ironpet"), ["Pull requests are squash merged and need one approval."])
    }

    func testAConventionAboutPullRequestsInGeneralIsKept() async {
        chat("t1", "PRs wait for review")
        answers = [#"{"notes":[{"scope":"project","entity":"IronPet","text":"PRs are ready for review once CI is green.","replaces":[]}],"links":[]}"#]
        await digest()
        XCTAssertEqual(texts("project:ironpet"), ["PRs are ready for review once CI is green."])
    }

    func testTheGuardRecognisesWorkItemNames() {
        for name in ["SSP-10435", "ticket SSP-10435", "#304", "304", "PR 12", "PR #12", "pr-12", "issue #304", "Issue 304", "ironpet#304",
                     "owner/repo#12", "https://github.com/o/r/pull/12", "https://x.atlassian.net/browse/SSP-10435"] {
            XCTAssertTrue(WorkItemGuard.isWorkItem(name), name)
        }
        for name in ["IronPet", "Self Service Portal", "GPT-4", "gpt-35", "Xcode 16", "Q3 planning", "C#", "Weber & Partner", ""] {
            XCTAssertFalse(WorkItemGuard.isWorkItem(name), name)
        }
        XCTAssertFalse(WorkItemGuard.isWorkItem(nil))
    }

    func testTheStoreRefusesAWorkItemPageFromAnyCaller() {
        let result = store.replace([], with: "Adds SSO.", scope: .project, entity: "SSP-10435", source: "chat:x")
        XCTAssertFalse(result.isSuccess)
        XCTAssertFalse(store.entities().contains { $0.name.contains("SSP") })
    }

    func testANamedScopeWithoutANameIsDropped() async {
        chat("t1", "Acme is a client")
        answers = [#"{"notes":[{"scope":"org","text":"Is a client.","replaces":[]}],"links":[]}"#]
        await digest()
        XCTAssertEqual(reflector.lastOutcome?.dropped.count, 1)
        XCTAssertTrue(store.entities().filter { $0.type == .org }.isEmpty)
    }

    func testThePromptListsExistingPagesSoTheAgentCanNameOne() async throws {
        try store.remember("Pays late", scope: .org, entity: "Acme", source: "chat:a").get()
        chat("t1", "Acme again")
        await digest()
        XCTAssertTrue(prompts[0].contains("org: Acme"))
        XCTAssertTrue(prompts[0].contains("\"entity\""))
    }

    // MARK: S3

    func testAnAliasOrIdentifierFindsTheExistingPageInsteadOfMakingASecondOne() async throws {
        try store.remember("Ships Fridays", scope: .project, entity: "Lighthouse", source: "chat:a").get()
        try store.database.write { db in
            try db.execute("UPDATE memory_entities SET aliases = 'LH', identifiers = 'github.com/acme/lighthouse' WHERE id = 'project:lighthouse'")
        }
        try store.remember("Uses SwiftUI", scope: .project, entity: "lh", source: "chat:b").get()
        try store.remember("Has a CI queue", scope: .project, entity: "github.com/acme/lighthouse", source: "chat:c").get()
        XCTAssertEqual(store.entities().filter { $0.type == .project }.count, 1)
        XCTAssertEqual(texts("project:lighthouse").count, 3)
    }

    func testTheSameNameOnAnotherTypeIsAnotherPage() throws {
        try store.remember("Chat app", scope: .project, entity: "Band", source: "chat:a").get()
        try store.remember("Team of six", scope: .org, entity: "Band", source: "chat:a").get()
        XCTAssertEqual(Set(store.entities().filter { $0.name == "Band" }.map(\.type)), [.project, .org])
    }

    func testTwoPagesWithTheNameRefuseTheNote() throws {
        try store.remember("A", scope: .tool, entity: "Alpha", source: "chat:a").get()
        try store.remember("B", scope: .tool, entity: "Beta", source: "chat:a").get()
        try store.database.write { db in try db.execute("UPDATE memory_entities SET aliases = 'Tool' WHERE type = 'tool'") }
        XCTAssertFalse(store.remember("C", scope: .tool, entity: "Tool", source: "chat:a").isSuccess)
    }

    func testForgetFindsNotesOnTheNewPages() throws {
        try store.remember("Pays invoices late", scope: .org, entity: "Acme", source: "chat:a").get()
        let removed = try store.forget("invoices", scope: nil, source: "chat:b").get()
        XCTAssertEqual(removed.map(\.page), ["Acme"])
        XCTAssertTrue(texts("org:acme").isEmpty)
    }

    // MARK: Entity pages on first mention (#368)

    private func meeting(_ summary: String) throws -> URL {
        let folder = dir.appendingPathComponent("2026-11-20 10-00 Sync")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try summary.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        return folder
    }

    func testAColleagueFromAnOrganizationGetsBothPagesAndALink() async throws {
        let folder = try meeting("Ana Silva from Epic Games joined and explained the licensing terms.")
        answers = [#"""
        {"notes":[],"entities":[{"name":"Ana Silva","type":"person"},{"name":"Epic Games","type":"organization"}],
        "links":[{"from":"Ana Silva","type":"works_at","to":"Epic Games"}]}
        """#]
        _ = await reflector.reflectNow(.meeting(folder, agent: "claude"))
        let org = try XCTUnwrap(store.entities().first { $0.name == "Epic Games" })
        let person = try XCTUnwrap(store.entities().first { $0.name == "Ana Silva" })
        XCTAssertEqual(org.type, .org)
        XCTAssertEqual(person.type, .person)
        let link = try XCTUnwrap(store.page(ref: person.ref)?.links.first)
        XCTAssertEqual([link.from, link.to, link.type], [person.id, org.id, "works_at"])
        XCTAssertTrue(prompts[0].contains("\"entities\""))
        XCTAssertTrue(prompts[0].contains("works_at"))
    }

    func testALinkToAnUnlistedUnknownNameStaysSkipped() async {
        chat("t1", "Ana works at Nowhere Inc")
        answers = [#"{"notes":[],"entities":[{"name":"Ana","type":"person"}],"links":[{"from":"Ana","type":"works_at","to":"Nowhere Inc"}]}"#]
        await digest()
        XCTAssertNil(store.entities().first { $0.name == "Nowhere Inc" })
        XCTAssertTrue(store.page(ref: store.entities().first { $0.name == "Ana" }?.ref ?? "")?.links.isEmpty ?? false)
    }

    func testAnAbbreviationInBracketsBecomesAnAlias() async throws {
        chat("t1", "The Self Service Portal (SSP) needs SSO")
        answers = [#"""
        {"notes":[{"scope":"project","entity":"SSP","text":"Needs SSO login.","replaces":[]}],
        "entities":[{"name":"Self Service Portal","type":"project","aliases":["SSP"]}],"links":[]}
        """#]
        await digest()
        let page = try store.page("SSP").get()
        XCTAssertEqual(page.entity.name, "Self Service Portal")
        XCTAssertEqual(page.entity.aliases, ["SSP"])
        XCTAssertEqual(try store.page("Self Service Portal").get().entity.ref, page.entity.ref)
        XCTAssertEqual(store.page(ref: page.entity.ref)?.entity.id, page.entity.id)
        XCTAssertEqual(texts(page.entity.id), ["Needs SSO login."], "the note goes on the main name, not a second page")
        XCTAssertEqual(store.entities().filter { $0.type == .project }.count, 1)
    }

    func testANoteLandsOnThePersonWhoseEmailIsOnAKnownPage() async throws {
        _ = try store.importPage(id: EntityMatcher.personID("Ana Silva"), type: .person, name: "Ana Silva", identifiers: ["ana@acme.com"],
                                 mentions: 2, notes: [MemoryNote(text: "Leads the platform team.", date: "2026-10-01", source: "chat:a")])
        let folder = try meeting("Attendees: ana@acme.com. A. Silva said the review is on Friday.")
        answers = [#"""
        {"notes":[{"scope":"people","person":"A. Silva","text":"Reviews on Fridays.","replaces":[]}],
        "entities":[{"name":"A. Silva","type":"person","identifiers":["ana@acme.com"]}],"links":[]}
        """#]
        _ = await reflector.reflectNow(.meeting(folder, agent: "claude"))
        XCTAssertEqual(texts("person:ana silva").sorted(), ["Leads the platform team.", "Reviews on Fridays."])
        XCTAssertEqual(store.entities().filter { $0.type == .person }.count, 1)
    }

    func testANoteNamingThePersonByEmailLandsOnThePage() async throws {
        _ = try store.importPage(id: EntityMatcher.personID("Ana Silva"), type: .person, name: "Ana Silva", identifiers: ["ana@acme.com"],
                                 mentions: 2, notes: [])
        let folder = try meeting("Attendees: ana@acme.com. Review is on Friday.")
        answers = [#"{"notes":[{"scope":"people","person":"ana@acme.com","text":"Reviews on Fridays.","replaces":[]}],"links":[]}"#]
        _ = await reflector.reflectNow(.meeting(folder, agent: "claude"))
        XCTAssertEqual(texts("person:ana silva"), ["Reviews on Fridays."])
        XCTAssertEqual(store.entities().filter { $0.type == .person }.count, 1)
    }

    func testAnOrganizationWithNoFactGetsAnEmptyPageThatRecordsWhereItCameUp() async throws {
        chat("t1", "We got a quote from Initech")
        answers = [#"{"notes":[],"entities":[{"name":"Initech","type":"org"}],"links":[]}"#]
        await digest()
        let page = try store.page("Initech").get()
        XCTAssertEqual(page.entity.type, .org)
        XCTAssertTrue(page.claims.isEmpty)
        XCTAssertEqual(page.entity.mentions, 1)
        XCTAssertEqual(page.entity.sources, ["chat:t1"])
        XCTAssertEqual(MemoryMCP.pageJSON(page)["mentionSources"] as? [String], ["chat:t1"])
        let row = try XCTUnwrap(store.browseRows().first { $0.name == "Initech" })
        XCTAssertEqual(row.factCount, 0)
        XCTAssertEqual(row.summary, "Mentioned in 1 place, no notes yet.")
        XCTAssertTrue(try XCTUnwrap(store.detail(page.entity.id)).markdown.contains("Mentioned in: chat:t1"))
    }

    func testTheSameSourceIsNotCountedTwiceButANewOneIs() async throws {
        let seen = EntityMemoryStore.SeenEntity(name: "Initech", type: .org)
        store.noteMention(seen, source: "chat:a")
        store.noteMention(seen, source: "chat:a")
        store.noteMention(seen, source: "chat:b")
        let entity = try XCTUnwrap(store.entities().first { $0.name == "Initech" })
        XCTAssertEqual(entity.mentions, 2)
        XCTAssertEqual(entity.sources, ["chat:a", "chat:b"])
    }

    func testAPersonMentionedOnceStaysAStub() async throws {
        chat("t1", "Bob joined the call")
        answers = [#"{"notes":[],"entities":[{"name":"Bob","type":"person"}],"links":[]}"#]
        await digest()
        XCTAssertEqual(try XCTUnwrap(store.entities().first { $0.name == "Bob" }).isStub, true)
        XCTAssertNil(store.browseRows().first { $0.name == "Bob" }, "a stub with no fact stays off the list")
        store.noteMention(EntityMemoryStore.SeenEntity(name: "Bob", type: .person), source: "chat:t2")
        XCTAssertNotNil(store.browseRows().first { $0.name == "Bob" })
    }

    func testAPageWithANoteAndAMentionFromOneChatCountsOnce() async throws {
        chat("t1", "Acme pays late")
        answers = [#"{"notes":[{"scope":"org","entity":"Acme","text":"Pays late.","replaces":[]}],"entities":[{"name":"Acme","type":"org"}],"links":[]}"#]
        await digest()
        XCTAssertEqual(store.entities().first { $0.id == "org:acme" }?.mentions, 1)
    }

    func testAWorkItemIsNeverAnEntityOrALinkEnd() async {
        chat("t1", "SSP-10435 and #304 for Self Service Portal")
        answers = [#"""
        {"notes":[],"entities":[{"name":"SSP-10435","type":"project"},{"name":"#304","type":"topic"},{"name":"ironpet#304","type":"tool"},
        {"name":"Self Service Portal","type":"project","aliases":["SSP-10435"]}],
        "links":[{"from":"SSP-10435","type":"part_of","to":"Self Service Portal"},{"from":"#304","type":"part_of","to":"Self Service Portal"}]}
        """#]
        await digest()
        XCTAssertEqual(store.entities().filter { $0.type != .me }.map(\.name), ["Self Service Portal"])
        XCTAssertEqual(store.entities().first { $0.type == .project }?.aliases, [])
        XCTAssertTrue(store.page(ref: store.entities().first { $0.type == .project }?.ref ?? "")?.links.isEmpty ?? false)
    }

    func testOnePassRecordsAtMostMaxEntitiesAndSkipsTheUserAndUnknownTypes() async {
        chat("t1", "many names")
        let many = (1...15).map { #"{"name":"Org \#($0)","type":"org"}"# }.joined(separator: ",")
        answers = [#"{"notes":[],"entities":[{"name":"Me","type":"me"},{"name":"X","type":"spaceship"},\#(many)],"links":[]}"#]
        await digest()
        XCTAssertEqual(store.entities().filter { $0.type == .org }.count, MemoryReflector.maxEntities)
        XCTAssertEqual(store.entities().filter { $0.type == .me }.count, 1)
    }

    func testAMentionOnlyPageIsRemovedLikeAnyOtherPage() async throws {
        chat("t1", "We got a quote from Initech")
        answers = [#"{"notes":[],"entities":[{"name":"Initech","type":"org"}],"links":[]}"#]
        await digest()
        let page = try XCTUnwrap(store.entities().first { $0.name == "Initech" })
        try store.remember("Sells copiers", scope: .org, entity: "Initech Ltd", source: "chat:b").get()
        let merged = try store.mergePages([page.id], into: "Initech Ltd").get()
        XCTAssertEqual(merged.merged.map(\.name), ["Initech"])
        XCTAssertNil(store.entities().first { $0.id == page.id })
        XCTAssertTrue(try XCTUnwrap(store.entities().first { $0.name == "Initech Ltd" }).sources.contains(page.sources[0]))
    }

    func testForgettingAMentionOnlyPageTakesItOffTheList() async throws {
        chat("t1", "We got a quote from Initech")
        answers = [#"{"notes":[],"entities":[{"name":"Initech","type":"org"}],"links":[]}"#]
        await digest()
        XCTAssertNotNil(store.browseRows().first { $0.name == "Initech" })
        XCTAssertTrue(store.forgetPage("org:initech", source: "settings"))
        XCTAssertNil(store.browseRows().first { $0.name == "Initech" })
    }

    func testPagesFromBeforeTheSourcesColumnHaveNoSources() throws {
        try store.remember("Pays late", scope: .org, entity: "Acme", source: "chat:a").get()
        XCTAssertEqual(store.entities().first { $0.id == "org:acme" }?.sources, ["chat:a"])
        let old = try store.importPage(id: "org:old", type: .org, name: "Old", identifiers: [], mentions: 1, notes: [MemoryNote(text: "Was here.", date: "2026-01-01", source: "chat:z")])
        XCTAssertEqual(old, 1)
        XCTAssertEqual(store.entities().first { $0.id == "org:old" }?.sources, [])
        XCTAssertEqual(store.browseRows().first { $0.id == "org:old" }?.factCount, 1)
    }

    // MARK: S5

    private func seedMisfiled() throws -> [String: Int64] {
        var ids: [String: Int64] = [:]
        for (text, day) in [("Ships every Friday.", "2026-10-01"), ("Pays invoices late.", "2026-10-02"), ("Tests run with swift test.", "2026-10-03")] {
            let source = "chat:" + text.prefix(3).lowercased()
            _ = try store.importPage(id: repoPage, type: .project, name: repo.name, identifiers: [repo.key], mentions: 2,
                                     notes: [MemoryNote(text: text, date: day, source: source)])
            ids[text] = try XCTUnwrap(store.claims(of: repoPage).first { $0.text == text }?.id)
        }
        return ids
    }

    private func classifier(_ answer: [String: (MemoryScope, String)]) -> MemoryResort.Classifier {
        { batch in batch.compactMap { item in answer[item.text].map { MemoryResort.Classification(ref: item.ref, scope: $0.0, entity: $0.1) } } }
    }

    func testTheResortMovesEachNoteKeepingItsDateAndSourceAndLogsIt() async throws {
        let ids = try seedMisfiled()
        let before = store.claims(of: repoPage).map { ($0.id, $0.ref, $0.date, $0.sources) }
        let moved = await MemoryResort.run(into: store, classify: classifier([
            "Ships every Friday.": (.project, "Lighthouse"),
            "Pays invoices late.": (.org, "Acme"),
            "Tests run with swift test.": (.project, repo.name),
        ]))
        XCTAssertEqual(moved, 2)
        XCTAssertEqual(texts("project:lighthouse"), ["Ships every Friday."])
        XCTAssertEqual(texts("org:acme"), ["Pays invoices late."])
        XCTAssertEqual(texts(repoPage), ["Tests run with swift test."], "a note about the repo stays")
        let friday = try XCTUnwrap(store.claims(of: "project:lighthouse").first)
        let was = try XCTUnwrap(before.first { $0.0 == ids["Ships every Friday."] })
        XCTAssertEqual(friday.id, was.0)
        XCTAssertEqual(friday.ref, was.1)
        XCTAssertEqual(friday.date, "2026-10-01")
        XCTAssertEqual(friday.sources, was.3)
        let changes = store.recentChanges().filter { $0.action == .moved }
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(Set(changes.map(\.previous)), [repoPage])
        XCTAssertEqual(Set(changes.map(\.file)), ["project:lighthouse", "org:acme"])
    }

    func testAMoveCanBeUndone() async throws {
        _ = try seedMisfiled()
        await MemoryResort.run(into: store, classify: classifier(["Pays invoices late.": (.org, "Acme")]))
        let change = try XCTUnwrap(store.recentChanges().first { $0.action == .moved })
        XCTAssertTrue(store.undo(change).isSuccess)
        XCTAssertTrue(texts("org:acme").isEmpty)
        XCTAssertTrue(texts(repoPage).contains("Pays invoices late."))
        XCTAssertEqual(store.claims(of: repoPage).first { $0.text == "Pays invoices late." }?.date, "2026-10-02")
    }

    func testAMoveIsRefusedWhenTheNoteChangedSince() async throws {
        _ = try seedMisfiled()
        await MemoryResort.run(into: store, classify: classifier(["Pays invoices late.": (.org, "Acme")]))
        let change = try XCTUnwrap(store.recentChanges().first { $0.action == .moved })
        _ = try store.forget("invoices", scope: .org, source: "chat:z").get()
        XCTAssertFalse(store.undo(change).isSuccess)
    }

    func testRunningTheResortAgainChangesNothing() async throws {
        _ = try seedMisfiled()
        let classify = classifier(["Pays invoices late.": (.org, "Acme")])
        let first = await MemoryResort.run(into: store, classify: classify)
        let changes = store.recentChanges().count
        let second = await MemoryResort.run(into: store, classify: classify)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(store.recentChanges().count, changes)
    }

    func testAFailedBatchIsNotRecordedSoTheNextRunTriesAgain() async throws {
        _ = try seedMisfiled()
        let failed = await MemoryResort.run(into: store) { _ in nil }
        XCTAssertNil(failed)
        XCTAssertFalse(MemoryResort.isDone(store))
        let retried = await MemoryResort.run(into: store, classify: classifier(["Pays invoices late.": (.org, "Acme")]))
        XCTAssertEqual(retried, 1)
    }

    func testPinnedNotesAndNotesTheModelDidNotSeeStay() async throws {
        let ids = try seedMisfiled()
        store.setPinned(try XCTUnwrap(ids["Pays invoices late."]), true)
        await MemoryResort.run(into: store) { _ in
            [MemoryResort.Classification(ref: "claim_unknown", scope: .org, entity: "Ghost Corp")]
        }
        XCTAssertEqual(texts(repoPage).count, 3)
        XCTAssertTrue(store.entities().filter { $0.type == .org }.isEmpty)
    }

    func testTheDigestRunsTheResortThroughTheAgentOnce() async throws {
        _ = try seedMisfiled()
        answers = [#"{"moves":[{"ref":"\#(try XCTUnwrap(store.claims(of: repoPage).first { $0.text == "Pays invoices late." }?.ref))","scope":"org","entity":"Acme"}]}"#]
        await digest()
        XCTAssertEqual(texts("org:acme"), ["Pays invoices late."])
        XCTAssertTrue(prompts[0].contains("Pays invoices late."))
        XCTAssertTrue(MemoryResort.isDone(store))
        let calls = prompts.count
        clock = clock.addingTimeInterval(7_200)
        await digest()
        XCTAssertEqual(prompts.count, calls, "a second digest does not ask again")
    }

    func testParseMovesSkipsBadEntries() {
        let moves = MemoryResort.parse(#"{"moves":[{"ref":"claim_a","scope":"org","entity":"Acme"},{"ref":"claim_b","scope":"nope","entity":"X"},{"ref":"claim_c"}]}"#)
        XCTAssertEqual(moves, [MemoryResort.Classification(ref: "claim_a", scope: .org, entity: "Acme")])
        XCTAssertNil(MemoryResort.parse("not json"))
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}
