import XCTest
@testable import IronPet
@testable import IronPetCore

@MainActor
final class MemoryMCPTests: XCTestCase {
    private var dir: URL!
    private var store: EntityMemoryStore!
    private var index: MemoryIndex!
    private var screen: CaptureStore!
    private var threads: [String: ChatThread] = [:]
    private var workspace: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-memory-mcp-\(UUID().uuidString)")
        workspace = dir.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let database = try Database(path: nil, migrations: AppMigrations.all)
        screen = CaptureStore(database: database)
        store = EntityMemoryStore(database: database)
        index = store.index
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var services: MemoryMCP.Services {
        MemoryMCP.Services(store: store, index: index, screen: screen, context: { [workspace] in ("3f2a9c1d-session", workspace) },
                           thread: { [threads] in threads[$0] })
    }

    private func call(_ name: String, _ args: [String: Any], caller: String? = nil) async throws -> (value: [String: Any], isError: Bool, text: String) {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]])
        let (_, data) = await MCPEndpoint.handle(body, automations: nil, tasks: nil, screen: screen.map { ScreenAPI(service: CaptureService(store: $0, config: { Config().screenCapture })) },
                                                 memory: MemoryAPI(services: { [services] in services }), caller: caller)
        let result = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return (value, result["isError"] as? Bool ?? false, text)
    }

    func testRememberWritesTheClaimWithTheChatAsItsSource() async throws {
        let saved = try await call("memory_remember", ["text": "Prefers pnpm over npm", "scope": "me"])
        XCTAssertFalse(saved.isError, saved.text)
        XCTAssertEqual(saved.value["page"] as? String, "me")
        XCTAssertEqual(store.claims(of: "me").first?.sources, ["chat:3f2a9c1d"])
        let project = try await call("memory_remember", ["text": "Tests run with swift test", "scope": "project"])
        XCTAssertFalse(project.isError, project.text)
        XCTAssertEqual(store.claims(of: "project:" + ProjectKey.of(workspace).key).map(\.text), ["Tests run with swift test"])
    }

    func testRememberFilesANoteOnTheNamedOrganizationToolOrTopicAndSearchAndTheBrowserFindThem() async throws {
        let org = try await call("memory_remember", ["text": "Pays invoices late", "scope": "org", "entity": "Acme"])
        XCTAssertFalse(org.isError, org.text)
        XCTAssertEqual(org.value["page"] as? String, "Acme")
        _ = try await call("memory_remember", ["text": "Crashes on large catalogs", "scope": "tool", "entity": "Xcode"])
        _ = try await call("memory_remember", ["text": "Moving to monthly billing", "scope": "topic", "entity": "Invoicing"])
        let product = try await call("memory_remember", ["text": "Ships Fridays", "scope": "project", "entity": "Lighthouse"])
        XCTAssertFalse(product.isError, product.text)
        XCTAssertEqual(store.claims(of: "org:acme").map(\.text), ["Pays invoices late"])
        XCTAssertEqual(store.claims(of: "tool:xcode").map(\.text), ["Crashes on large catalogs"])
        XCTAssertEqual(store.claims(of: "topic:invoicing").map(\.text), ["Moving to monthly billing"])
        XCTAssertEqual(store.claims(of: "project:lighthouse").map(\.text), ["Ships Fridays"])
        XCTAssertTrue(store.claims(of: "project:" + ProjectKey.of(workspace).key).isEmpty)
        let page = try await call("memory_page", ["name": "Acme"])
        XCTAssertEqual(page.value["type"] as? String, "org")
        let search = try await call("memory_search", ["query": "catalogs", "kinds": ["note"]])
        XCTAssertEqual(search.value["count"] as? Int, 1)
        let rows = MemoryBrowser.rows(entities: store.entities(), claims: Dictionary(uniqueKeysWithValues: store.entities().map { ($0.id, store.claims(of: $0.id)) }))
        let types = Set(rows.map(\.type))
        XCTAssertTrue(types.isSuperset(of: [.org, .tool, .topic, .project]))
        XCTAssertEqual(MemoryBrowser.list(rows, filter: .tools, query: "xcode").rows.map(\.name), ["Xcode"])
    }

    func testANamedScopeNeedsAName() async throws {
        let missing = try await call("memory_remember", ["text": "Pays late", "scope": "org"])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("entity"))
    }

    func testRememberRefusesSecretsAndMissingFields() async throws {
        let secret = try await call("memory_remember", ["text": "AWS key AKIAIOSFODNN7EXAMPLE", "scope": "me"])
        XCTAssertTrue(secret.isError)
        XCTAssertTrue(secret.text.contains("not saved"))
        XCTAssertTrue(store.claims(of: "me").isEmpty)
        let noScope = try await call("memory_remember", ["text": "x"])
        XCTAssertTrue(noScope.isError)
        let badScope = try await call("memory_remember", ["text": "x", "scope": "world"])
        XCTAssertTrue(badScope.text.contains("scope is me, project or people"))
        let noPerson = try await call("memory_remember", ["text": "Likes tea", "scope": "people"])
        XCTAssertTrue(noPerson.text.contains("person's name"))
    }

    func testForgetMovesTheClaimToHistoryAndSaysWhatWentAway() async throws {
        _ = try await call("memory_remember", ["text": "Prefers pnpm over npm", "scope": "me"])
        _ = try await call("memory_remember", ["text": "Works in Helsinki", "scope": "me"])
        let forgot = try await call("memory_forget", ["query": "pnpm"])
        XCTAssertFalse(forgot.isError, forgot.text)
        XCTAssertEqual((forgot.value["removed"] as? [[String: Any]])?.first?["note"] as? String, "Prefers pnpm over npm")
        XCTAssertEqual(store.claims(of: "me").map(\.text), ["Works in Helsinki"])
        XCTAssertEqual(store.history(of: "me").map(\.text), ["Prefers pnpm over npm"], "the claim is kept for undo")
        let again = try await call("memory_forget", ["query": "pnpm"])
        XCTAssertTrue(again.isError)
    }

    func testMergeMovesTheFactsAndSaysWhatMoved() async throws {
        for index in 1...3 { _ = try await call("memory_remember", ["text": "Irtaza fact \(index)", "scope": "people", "person": "Irtaza"]) }
        _ = try await call("memory_remember", ["text": "Lives in Berlin", "scope": "people", "person": "Irtaza Hashimi"])
        let merged = try await call("memory_merge", ["keep": "Irtaza Hashimi", "merge": ["Irtaza"]])
        XCTAssertFalse(merged.isError, merged.text)
        XCTAssertEqual(merged.value["kept"] as? String, "Irtaza Hashimi")
        XCTAssertEqual(merged.value["facts"] as? Int, 4)
        XCTAssertEqual(merged.value["aliases"] as? [String], ["Irtaza"])
        XCTAssertEqual((merged.value["merged"] as? [[String: Any]])?.first?["facts"] as? Int, 3)
        XCTAssertEqual(store.entities().filter { $0.type == .person }.map(\.name), ["Irtaza Hashimi"])
        let later = try await call("memory_remember", ["text": "Likes tea", "scope": "people", "person": "Irtaza"])
        XCTAssertFalse(later.isError, later.text)
        let page = try await call("memory_page", ["name": "Irtaza"])
        XCTAssertEqual(page.value["entity"] as? String, "Irtaza Hashimi")
        XCTAssertEqual((page.value["claims"] as? [[String: Any]])?.count, 5)
    }

    func testMergeNeedsKeepAndMergeAndRefusesWhatCannotMerge() async throws {
        _ = try await call("memory_remember", ["text": "Owns the repo", "scope": "project", "entity": "Maya"])
        _ = try await call("memory_remember", ["text": "Lives in Berlin", "scope": "people", "person": "Maya"])
        let noKeep = try await call("memory_merge", ["merge": ["Maya"]])
        let noMerge = try await call("memory_merge", ["keep": "Maya"])
        XCTAssertTrue(noKeep.isError)
        XCTAssertTrue(noMerge.isError)
        let mixed = try await call("memory_merge", ["keep": "person:maya", "merge": ["project:maya"]])
        XCTAssertTrue(mixed.isError)
        XCTAssertTrue(mixed.text.contains("only pages of one type merge"), mixed.text)
        let outside = try await call("memory_merge", ["keep": "person:maya", "merge": ["project:maya"]], caller: "anything")
        XCTAssertEqual(outside.text, "only the user's chat may merge pages")
        XCTAssertEqual(store.entities().filter { $0.name == "Maya" }.count, 2, "nothing merged")
    }

    func testTheCLIMergesThroughTheSameTool() throws {
        _ = store.remember("Lives in Berlin", scope: .people, person: "Irtaza Hashimi", source: "chat:a")
        _ = store.remember("Writes Swift", scope: .people, person: "Irtaza", source: "chat:a")
        let request = try MemoryCLI.request(["merge", "Irtaza Hashimi", "Irtaza"])
        XCTAssertEqual(request.op, "merge")
        XCTAssertEqual(request.args["keep"] as? String, "Irtaza Hashimi")
        XCTAssertEqual(request.args["merge"] as? [String], ["Irtaza"])
        XCTAssertThrowsError(try MemoryCLI.request(["merge", "Irtaza"]))
        XCTAssertThrowsError(try MemoryCLI.request(["forget", "x"]))

        let body = try JSONSerialization.data(withJSONObject: ["op": request.op, "args": request.args])
        let reply = MemoryMCP.handleCLI(body, api: MemoryAPI(services: { [services] in services }))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: reply.body) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true, "\(object)")
        XCTAssertEqual((object["result"] as? [String: Any])?["facts"] as? Int, 2)
        XCTAssertEqual(store.entities().filter { $0.type == .person }.map(\.name), ["Irtaza Hashimi"])
        let failed = MemoryMCP.handleCLI(Data(#"{"op":"merge","args":{"keep":"Nobody","merge":["Irtaza"]}}"#.utf8), api: MemoryAPI(services: { [services] in services }))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: failed.body) as? [String: Any])?["ok"] as? Bool, false)
    }

    func testSearchFindsChatsNotesAndTheScreenButNotForgottenClaims() async throws {
        let item = ChatSession.Item(kind: .user("I always use pnpm, never npm"))
        let thread = ChatThread(id: "t1", title: "Packages", workspace: workspace.path, updatedAt: Date(),
                                items: [item, .init(kind: .assistant("Got it, pnpm."))], agent: "claude")
        threads["t1"] = thread
        index.indexThread(thread)
        index.flush()
        _ = try await call("memory_remember", ["text": "Prefers pnpm over npm", "scope": "me"])
        _ = try await call("memory_forget", ["query": "pnpm"])
        _ = try screen.ingest(app: CaptureApp(bundleId: "com.apple.Safari", name: "Safari"), title: "pnpm docs", url: nil, trigger: .click,
                              lines: ["pnpm install is fast"])
        let all = try await call("memory_search", ["query": "pnpm"])
        let kinds = (all.value["hits"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
        XCTAssertEqual(Set(kinds), ["chat", "screen"], "the forgotten note is not found")
        let history = try await call("memory_search", ["query": "pnpm", "kinds": ["history"]])
        XCTAssertTrue(history.isError, "history is not a search kind; memory_page shows it")
        let chats = try await call("memory_search", ["query": "never npm", "kinds": ["chat"]])
        let hit = try XCTUnwrap((chats.value["hits"] as? [[String: Any]])?.first)
        XCTAssertEqual(hit["id"] as? String, "chat:t1/\(item.id.uuidString)")
        let excerpt = try await call("memory_get", ["id": hit["id"] as! String])
        let messages = try XCTUnwrap(excerpt.value["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant"])
        XCTAssertEqual(messages.first?["hit"] as? Bool, true)
        XCTAssertEqual(excerpt.value["thread"] as? String, "Packages")
    }

    func testAnAutomationSessionIsOutsideTextAndCannotWriteMeOrForget() async throws {
        _ = try await call("memory_remember", ["text": "Prefers tea", "scope": "me"])
        let me = try await call("memory_remember", ["text": "Prefers coffee", "scope": "me"], caller: "automation:mail")
        XCTAssertTrue(me.isError)
        XCTAssertTrue(me.text.contains("may not save notes about the user"))
        let forget = try await call("memory_forget", ["query": "tea"], caller: "automation:mail")
        XCTAssertTrue(forget.isError)
        XCTAssertEqual(store.claims(of: "me").map(\.text), ["Prefers tea"])
        let project = try await call("memory_remember", ["text": "Uses Make", "scope": "project"], caller: "automation:mail")
        XCTAssertTrue(project.isError, "no project is taken from the chat that happens to be open")
        let person = try await call("memory_remember", ["text": "Sends the invoices", "scope": "people", "person": "Ana"], caller: "automation:mail")
        XCTAssertFalse(person.isError, person.text)
        XCTAssertEqual(store.claims(of: EntityMatcher.personID("Ana")).first?.sources, ["automation:mail"])
    }

    func testAnAutomationSessionNamesItselfToTheIronpetServerOnly() {
        let saved = ACPBackend.defaultMCPServers
        defer { ACPBackend.defaultMCPServers = saved }
        ACPBackend.defaultMCPServers = { [["name": "ironpet", "command": "/x", "args": ["mcp"], "env": [JSON]()], ["name": "other", "command": "/y"]] }
        let backend = ACPBackend(agent: AgentCatalog.agent(id: "claude")!, spawner: POSIXProcessSpawner())
        XCTAssertNil((backend.sessionMCPServers.first?["env"] as? [JSON])?.first)
        backend.mcpCaller = "automation:mail"
        let env = backend.sessionMCPServers.first?["env"] as? [JSON]
        XCTAssertEqual(env?.first?["name"] as? String, MCPEndpoint.callerVariable)
        XCTAssertEqual(env?.first?["value"] as? String, "automation:mail")
        XCTAssertNil(backend.sessionMCPServers.last?["env"])
        backend.restricted = true
        XCTAssertTrue(backend.sessionMCPServers.isEmpty)
    }

    func testAnAutomationSessionMayNotEditFilesInTheOldMemoryFolder() {
        let memoryEdit = ACPToolCall(id: "1", title: "Edit", kind: "edit", paths: [LegacyMemoryFiles.directory.appendingPathComponent("me.md").path])
        XCTAssertFalse(AutomationSession.decision(for: memoryEdit).allow)
        XCTAssertFalse(AutomationPrompt.decision(for: memoryEdit).allow, "the {{item.*}} run carries outside text")
        let moveIn = ACPToolCall(id: "3", title: "Move", kind: "move", rawInput: ["source": "/tmp/x.md", "destination": LegacyMemoryFiles.directory.appendingPathComponent("me.md").path],
                                 paths: ["/tmp/x.md"])
        XCTAssertFalse(AutomationSession.decision(for: moveIn).allow, "a move into the old memory folder asks")
        XCTAssertTrue(AutomationPrompt.decision(for: ACPToolCall(id: "2", title: "Read", kind: "read", paths: ["/tmp/x"])).allow)
        let otherEdit = ACPToolCall(id: "2", title: "Edit", kind: "edit", paths: ["/tmp/work/app.swift"])
        XCTAssertFalse(AutomationSession.decision(for: otherEdit).allow, "an edit is not answered without asking")
    }

    func testScreenIsLeftOutWhenCaptureHasNoData() async throws {
        let result = try await call("memory_search", ["query": "anything", "kinds": ["screen"]])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.value["count"] as? Int, 0)
    }

    func testGetReadsANoteAndRefusesUnknownIds() async throws {
        _ = try await call("memory_remember", ["text": "Uses zsh", "scope": "me"])
        let found = try await call("memory_search", ["query": "zsh", "kinds": ["note"]])
        let hit = try XCTUnwrap((found.value["hits"] as? [[String: Any]])?.first { ($0["id"] as? String)?.hasPrefix("note:") == true })
        let note = try await call("memory_get", ["id": hit["id"] as! String])
        XCTAssertEqual(note.value["note"] as? String, "Uses zsh")
        let unknown = try await call("memory_get", ["id": "chat:nope/none"])
        XCTAssertTrue(unknown.isError)
        let bad = try await call("memory_get", ["id": "nonsense"])
        XCTAssertTrue(bad.isError)
    }

    func testPageReadsAnEntityWithItsClaimsAndRefusesUnknownNames() async throws {
        _ = try await call("memory_remember", ["text": "Leads payments", "scope": "people", "person": "Ana"])
        _ = try await call("memory_remember", ["text": "Owns auth", "scope": "people", "person": "Ana"])
        let page = try await call("memory_page", ["name": "Ana"])
        XCTAssertFalse(page.isError, page.text)
        XCTAssertEqual(page.value["entity"] as? String, "Ana")
        XCTAssertEqual(page.value["type"] as? String, "person")
        let claims = try XCTUnwrap(page.value["claims"] as? [[String: Any]])
        XCTAssertEqual(Set(claims.compactMap { $0["text"] as? String }), ["Leads payments", "Owns auth"])
        XCTAssertTrue(claims.allSatisfy { ($0["id"] as? String)?.hasPrefix("claim_") == true })
        XCTAssertEqual((page.value["ref"] as? String)?.hasPrefix("page_"), true)
        let links = try await call("memory_links", ["name": "Ana"])
        XCTAssertEqual((links.value["links"] as? [Any])?.count, 0, "no links until the digest writes some")
        let unknown = try await call("memory_page", ["name": "Nobody"])
        XCTAssertTrue(unknown.isError)
    }

    func testBadTimesAndKindsAreErrors() async throws {
        let time = try await call("memory_search", ["query": "x", "since": "last tuesday"])
        XCTAssertTrue(time.isError)
        let kind = try await call("memory_search", ["query": "x", "kinds": ["email"]])
        XCTAssertTrue(kind.text.contains("unknown kinds"))
    }

    func testWithoutServicesTheToolsSayTheyAreUnavailable() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                               "params": ["name": "memory_search", "arguments": ["query": "x"]]])
        let (_, data) = await MCPEndpoint.handle(body, automations: nil, tasks: nil)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("memory is not available"))
    }

    func testTheNoProjectFolderHasNoProject() {
        XCTAssertNil(MemoryMCP.project(ChatSession.scratchWorkspace))
        XCTAssertNil(MemoryMCP.project(nil))
        XCTAssertEqual(MemoryMCP.source(thread: nil), "agent")
    }
}
