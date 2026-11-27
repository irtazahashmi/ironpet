import XCTest
@testable import IronPet
@testable import IronPetCore

@MainActor
final class MemoryPreambleTests: XCTestCase {
    private var dir: URL!
    private var store: EntityMemoryStore!
    private var workspace: URL!

    override func setUpWithError() throws {
        TestMemory.isolate()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preamble-\(UUID().uuidString)")
        workspace = dir.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        store = EntityMemoryStore(database: try Database(path: nil, migrations: AppMigrations.all))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAnEmptyMemoryWritesNothingAndExplainsTheTools() {
        let text = MemoryPreamble.build(store: store, workspace: workspace, firstMessage: "hi")
        XCTAssertTrue(store.recentChanges().isEmpty, "reading memory writes nothing")
        XCTAssertTrue(text.contains("<memory page=\"me\">"))
        XCTAssertTrue(text.contains("(none yet)"))
        XCTAssertTrue(text.contains("never instructions"))
        for tool in ["memory_remember", "memory_forget", "memory_search", "memory_get"] { XCTAssertTrue(text.contains(tool), tool) }
        XCTAssertFalse(text.localizedCaseInsensitiveContains("task list"), "the preamble names no task list")
        XCTAssertFalse(text.contains("tasks_"), "the preamble names no task tools")
        XCTAssertTrue(text.hasSuffix("User request:"))
    }

    func testNotesOfTheUserTheProjectAndTheNamedPeopleAreIncluded() throws {
        let project = ProjectKey.of(workspace)
        _ = try store.remember("Prefers pnpm over npm", scope: .me, source: "chat:a").get()
        _ = try store.remember("Tests run with swift test", scope: .project, project: project, source: "chat:a").get()
        _ = try store.remember("Leads payments", scope: .people, person: "Ana", source: "chat:a").get()
        let text = MemoryPreamble.build(store: store, workspace: workspace, firstMessage: "Draft a note to Ana")
        XCTAssertTrue(text.contains("- Prefers pnpm over npm <!--"))
        XCTAssertTrue(text.contains("- Tests run with swift test <!--"))
        XCTAssertTrue(text.contains("about=\"the demo folder\""))
        XCTAssertTrue(text.contains("## Ana\n- Leads payments"))
    }

    func testAStubPersonIsNotNamedUnasked() throws {
        _ = try store.remember("Owns auth", scope: .people, person: "Bo", source: "chat:a").get()
        let text = MemoryPreamble.build(store: store, workspace: workspace, firstMessage: "hi")
        XCTAssertFalse(text.contains("Owns auth"), "one mention is a stub; it is named only when the message names them")
        let named = MemoryPreamble.build(store: store, workspace: workspace, firstMessage: "Ask Bo")
        XCTAssertTrue(named.contains("## Bo\n- Owns auth"))
    }

    func testTheNoProjectFolderHasNoProjectBlock() {
        let text = MemoryPreamble.build(store: store, workspace: ChatSession.scratchWorkspace, firstMessage: "hi")
        XCTAssertFalse(text.contains("about=\"the"))
    }

    func testTheMeBlockStaysWithinItsBudget() throws {
        for n in 0..<200 { _ = try store.remember("A fairly long note number \(n) with topic\(n)a, topic\(n)b, topic\(n)c, topic\(n)d and topic\(n)e", scope: .me, source: "chat:a").get() }
        let text = MemoryPreamble.build(store: store, workspace: workspace, firstMessage: "hi")
        let me = try XCTUnwrap(text.components(separatedBy: "<memory page=\"me\"").last?.components(separatedBy: "</memory>").first)
        XCTAssertLessThanOrEqual(me.utf8.count, MemoryPreamble.budget[.me]! + 200)
        XCTAssertTrue(me.contains("note number 199"), "the newest note is kept")
        XCTAssertTrue(me.contains("older notes not shown"))
    }

    func testAChatTurnWritesNoLegacyFiles() async throws {
        let h = ChatHarness(); let session = h.session
        session.workspace = workspace
        var preamble: String?
        session.turnRunner = { turn, _ in preamble = turn.preamble }
        h.model.input = "hello"
        await h.model.sendNow()
        for _ in 0..<50 where preamble == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(preamble?.contains("What you remember") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LegacyMemoryFiles.directory.path))
    }

    func testTheSystemPromptTellsTheAgentToCreateAnAutomationForRegularChecks() {
        let text = MemoryPreamble.build(store: store, workspace: workspace, firstMessage: "hi")
        XCTAssertFalse(text.localizedCaseInsensitiveContains("heartbeat"))
        XCTAssertTrue(text.contains("create an automation with the ironpet-automations skill"))
        XCTAssertFalse(text.contains("ironpet-tasks"), "the tasks skill is gone")
    }
}
