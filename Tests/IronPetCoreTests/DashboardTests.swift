import XCTest
import IronPetKit
@testable import IronPetCore

@MainActor
final class DashboardTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-dashboards-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> DashboardStore { DashboardStore(paths: DashboardPaths(root: root), watch: false) }

    private func makeAPI(_ store: DashboardStore? = nil, sources: DashboardsAPI.Sources = .init(), host: DashboardRuntime.Host? = nil) -> DashboardsAPI {
        let api = DashboardsAPI(store: store ?? makeStore(), sources: sources)
        api.host = host ?? DashboardRuntime.Host()
        return api
    }

    private let countScript = """
        export default {
          view(ctx) { return Column([Stat({ label: "Inbox", value: String(ctx.data.count ?? 0) })]); }
        };
        """

    // MARK: Runtime

    func testViewBuildsNativeComponentsFromData() async throws {
        let script = """
            import { Column, Stat } from "ironpet";
            export default function (ctx) {
              return Column([
                Heading("Board"),
                Stat({ label: "Open", value: String(ctx.data.open), tone: "warn" }),
                List([{ title: "Fix", caption: "a", badge: "Failing", onClick: () => ironpet.setData({ clicked: true }) }]),
                Table({ columns: ["a"], rows: [[1], [2]] }),
                Chart({ kind: "bar", points: [1, 2, 3], labels: ["x", "y", "z"] }),
                Divider(),
              ]);
            }
            """
        let out = try await DashboardRuntime.render(script: script, data: ["open": 4], allowed: [], host: DashboardRuntime.Host())
        XCTAssertEqual(out.root.type, "column")
        let kids = try XCTUnwrap(out.root.children)
        XCTAssertEqual(kids.map(\.type), ["text", "stat", "list", "table", "chart", "divider"])
        XCTAssertEqual(kids[1].value, "4")
        XCTAssertEqual(kids[1].tone, "warn")
        XCTAssertEqual(kids[2].children?.first?.action, "h0")
        XCTAssertEqual(kids[3].rows, [["1"], ["2"]])
        XCTAssertEqual(kids[4].points, [1, 2, 3])
    }

    func testAScriptWithoutADefaultExportIsRejected() async {
        XCTAssertNotNil(DashboardRuntime.check("const a = 1;"))
        XCTAssertNil(DashboardRuntime.check(countScript))
        XCTAssertNotNil(DashboardRuntime.check("export default 5;"))
        XCTAssertNotNil(DashboardRuntime.check("this is not javascript ((("))
    }

    func testScriptHasNoWayOutExceptTheHostApi() async throws {
        let script = """
            export default () => Column([Text([typeof fetch, typeof require, typeof process, typeof setTimeout, typeof std, typeof os].join(","))]);
            """
        let out = try await DashboardRuntime.render(script: script, data: [:], allowed: [], host: DashboardRuntime.Host())
        XCTAssertEqual(out.root.children?.first?.text, "undefined,undefined,undefined,undefined,undefined,undefined")
    }

    func testARunawayScriptIsStopped() async {
        do {
            _ = try await DashboardRuntime.render(script: "export default () => { while (true) {} };", data: [:], allowed: [], host: DashboardRuntime.Host(), deadline: 0.3)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("too long"), "\(error)")
        }
    }

    // S3: until the user approves, the command does not run.
    func testACommandDoesNotRunUntilItIsApproved() async throws {
        let ran = Counter()
        let host = DashboardRuntime.Host(run: { command, args, _ in
            ran.value += 1
            return CommandResult(code: 0, stdout: "\(command) \(args.joined(separator: " "))")
        })
        let script = """
            export default {
              view(ctx) { return Column([Text(String(ctx.data.out ?? "none")), Button({ label: "Go", onClick: () => ironpet.setData({ out: ironpet.run("gh", ["pr", "list", "--json", "number"]).stdout }) })]); }
            };
            """
        let denied = try? await DashboardRuntime.click(script: script, data: [:], allowed: [], host: host, handler: "h0")
        XCTAssertNil(denied, "an unapproved command throws")
        XCTAssertEqual(ran.value, 0)
        do {
            _ = try await DashboardRuntime.click(script: script, data: [:], allowed: [], host: host, handler: "h0")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not an approved command"), "\(error)")
        }
        let allowed = try await DashboardRuntime.click(script: script, data: [:], allowed: ["run:gh pr list"], host: host, handler: "h0")
        XCTAssertEqual(ran.value, 1)
        XCTAssertEqual(allowed.patch["out"] as? String, "gh pr list --json number")
    }

    func testRunMatchesWholeWordsOfTheApprovedPrefix() {
        XCTAssertTrue(DashboardRuntime.runAllowed("gh pr list", by: ["run:gh pr list"]))
        XCTAssertTrue(DashboardRuntime.runAllowed("gh pr list --json x", by: ["run:gh pr list"]))
        XCTAssertFalse(DashboardRuntime.runAllowed("gh pr listing", by: ["run:gh pr list"]))
        XCTAssertFalse(DashboardRuntime.runAllowed("gh pr merge 1", by: ["run:gh pr list"]))
        XCTAssertFalse(DashboardRuntime.runAllowed("gh", by: ["run:gh pr list"]))
        XCTAssertFalse(DashboardRuntime.runAllowed("rm -rf /", by: ["network:api.github.com", "prompt"]))
    }

    func testNetworkOnlyReachesApprovedHosts() async throws {
        let host = DashboardRuntime.Host(fetch: { url, _, _, _, _ in .init(status: 200, body: url.absoluteString) })
        let script = "export default { view() { return Column([Button({ label: 'x', onClick: () => ironpet.setData({ body: ironpet.fetch('https://api.github.com/x').body }) })]); } };"
        let ok = try await DashboardRuntime.click(script: script, data: [:], allowed: ["network:api.github.com"], host: host, handler: "h0")
        XCTAssertEqual(ok.patch["body"] as? String, "https://api.github.com/x")
        do {
            _ = try await DashboardRuntime.click(script: script, data: [:], allowed: ["network:example.com"], host: host, handler: "h0")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not an approved host"), "\(error)")
        }
    }

    func testReadingIronPetDataNeedsTheCapability() async throws {
        let host = DashboardRuntime.Host(read: { name in name == "inbox" ? [["id": "1", "title": "Reply"]] : [] })
        let script = "export default { view() { return Column([Text(String(ironpet.inbox().length))]); } };"
        do {
            _ = try await DashboardRuntime.render(script: script, data: [:], allowed: [], host: host)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not approved"), "\(error)")
        }
        let out = try await DashboardRuntime.render(script: script, data: [:], allowed: ["read:inbox"], host: host)
        XCTAssertEqual(out.root.children?.first?.text, "1")
    }

    func testPromptsAndOpensHappenOnlyOnAClick() async throws {
        let script = """
            export default {
              view() {
                ironpet.open("https://example.com");
                return Column([]);
              }
            };
            """
        do {
            _ = try await DashboardRuntime.render(script: script, data: [:], allowed: ["prompt"], host: DashboardRuntime.Host())
            XCTFail("a view must not open links")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("only when the user clicks"), "\(error)")
        }
        let clickScript = """
            export default { view() { return Column([
              Button({ label: "Ask", onClick: () => ironpet.prompt("What is in my inbox?") }),
              Button({ label: "Docs", onClick: { open: "https://example.com/docs" } }),
              Button({ label: "Bad", onClick: { open: "javascript:alert(1)" } }),
            ]); } };
            """
        let ask = try await DashboardRuntime.click(script: clickScript, data: [:], allowed: ["prompt"], host: DashboardRuntime.Host(), handler: "h0")
        XCTAssertEqual(ask.effects, [.init(kind: "prompt", value: "What is in my inbox?")])
        let noPrompt = try? await DashboardRuntime.click(script: clickScript, data: [:], allowed: [], host: DashboardRuntime.Host(), handler: "h0")
        XCTAssertNil(noPrompt, "a prompt needs the capability")
        let docs = try await DashboardRuntime.click(script: clickScript, data: [:], allowed: [], host: DashboardRuntime.Host(), handler: "h1")
        XCTAssertEqual(docs.effects, [.init(kind: "open", value: "https://example.com/docs")])
        let bad = try? await DashboardRuntime.click(script: clickScript, data: [:], allowed: [], host: DashboardRuntime.Host(), handler: "h2")
        XCTAssertNil(bad, "only http and https links open")
    }

    func testAViewCannotChangeTheInboxWhileAClickReRendersIt() async throws {
        let script = """
            export default { view() {
              ironpet.inboxDone("a");
              return Column([Button({ label: "Go", onClick: () => ironpet.setData({ clicked: true }) })]);
            } };
            """
        nonisolated(unsafe) var writes: [String] = []
        let host = DashboardRuntime.Host(write: { op, id in writes.append("\(op):\(id)"); return nil })
        let outcome = try? await DashboardRuntime.click(script: script, data: [:], allowed: ["write:inbox"], host: host, handler: "h0")
        XCTAssertNil(outcome, "the view's call is refused, so the click fails")
        XCTAssertEqual(writes, [], "nothing reached the inbox")
    }

    // MARK: Store, approval and storage

    func testStoreWritesFilesAndReloadsAnEdit() throws {
        let store = makeStore()
        try store.create(id: "work", manifest: DashboardManifest(title: "Work"), script: countScript)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("work/manifest.json").path))
        XCTAssertEqual(store.dashboards.map(\.id), ["work"])
        // An edit on disk, as an agent or an editor would make it, is picked up.
        try Data("export default () => Column([]);".utf8).write(to: root.appendingPathComponent("work/main.js"))
        let later = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: root.appendingPathComponent("work/main.js").path)
        store.reload()
        XCTAssertEqual(store.dashboard("work")?.script, "export default () => Column([]);")
    }

    func testABadManifestIsLeftOutAndReported() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("broken"), withIntermediateDirectories: true)
        try Data(#"{"title": "x", "icon": "not a symbol!"}"#.utf8).write(to: root.appendingPathComponent("broken/manifest.json"))
        store.reload(force: true)
        XCTAssertTrue(store.dashboards.isEmpty)
        XCTAssertNotNil(store.problems["broken"])
    }

    // S4: an approved dashboard that gains a capability asks again, and only for the new one.
    func testAnEditThatAddsACapabilityAsksAgain() throws {
        let store = makeStore()
        try store.create(id: "work", manifest: DashboardManifest(title: "Work", capabilities: .init(run: ["gh pr list"], prompt: true)), script: countScript)
        XCTAssertEqual(store.undecided("work"), ["run:gh pr list", "prompt"])
        XCTAssertEqual(store.allowed("work"), [], "nothing runs before the user approves")
        try store.approve("work")
        XCTAssertEqual(store.undecided("work"), [])
        XCTAssertEqual(store.allowed("work"), ["run:gh pr list", "prompt"])
        try store.update("work", manifest: DashboardManifest(title: "Work", capabilities: .init(run: ["gh pr list", "gh pr view"], write: ["inbox"], prompt: true)))
        XCTAssertEqual(store.undecided("work"), ["run:gh pr view", "write:inbox"])
        XCTAssertEqual(store.allowed("work"), ["run:gh pr list", "prompt"], "the new capabilities do not run until approved")
        try store.deny("work")
        XCTAssertEqual(store.undecided("work"), [])
        XCTAssertEqual(store.allowed("work"), ["run:gh pr list", "prompt"], "a denial keeps what was approved before")
    }

    func testApprovalsSurviveARestartAndAreNotInTheDashboardFolder() throws {
        let store = makeStore()
        try store.create(id: "work", manifest: DashboardManifest(title: "Work", capabilities: .init(prompt: true)), script: countScript)
        try store.approve("work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("work/approvals.json").path))
        let again = makeStore()
        XCTAssertEqual(again.allowed("work"), ["prompt"])
    }

    func testAFolderRemovedByHandTakesItsApprovalsWithIt() throws {
        let store = makeStore()
        try store.create(id: "work", manifest: DashboardManifest(title: "Work", capabilities: .init(prompt: true)), script: countScript)
        try store.approve("work")
        try FileManager.default.removeItem(at: root.appendingPathComponent("work"))
        store.reload()
        try store.create(id: "work", manifest: DashboardManifest(title: "Work", capabilities: .init(prompt: true)), script: countScript)
        XCTAssertEqual(store.undecided("work"), ["prompt"], "a new dashboard with a reused id starts unapproved")
    }

    func testStorageMergesAndRemovesKeys() throws {
        let store = makeStore()
        try store.create(id: "work", manifest: DashboardManifest(title: "Work"), script: countScript)
        try store.merge("work", ["count": 3, "name": "a"])
        try store.merge("work", ["name": NSNull(), "extra": ["x": 1]])
        let data = store.data("work")
        XCTAssertEqual(data["count"] as? Int, 3)
        XCTAssertNil(data["name"])
        XCTAssertNotNil(data["extra"])
        XCTAssertThrowsError(try store.setData("work", ["big": String(repeating: "x", count: DashboardStore.maxStorageBytes)]))
        XCTAssertThrowsError(try store.merge("missing", ["a": 1]))
    }

    // MARK: API

    // S2
    func testTheSidebarCountFollowsTheManifestAndTheData() throws {
        XCTAssertEqual(DashboardCount.value(showsCount: true, reported: nil, data: ["count": 3]), 3)
        XCTAssertNil(DashboardCount.value(showsCount: false, reported: nil, data: ["count": 3]), "count turned off shows no number")
        XCTAssertEqual(DashboardCount.value(showsCount: true, reported: 7, data: ["count": 3]), 7, "what the script reports wins")
        XCTAssertNil(DashboardCount.value(showsCount: true, reported: nil, data: [:]))
        XCTAssertEqual(DashboardCount.value(showsCount: true, reported: nil, data: ["count": -2]), 0)
        let api = makeAPI()
        let made = try api.create(CreateDashboardRequest(title: "Inbox count", count: true, script: countScript))
        XCTAssertEqual(made.id, "inbox-count")
        XCTAssertNil(made.count)
        try api.post(id: "inbox-count", patch: ["count": 3])
        XCTAssertEqual(api.list().first?.count, 3)
        try api.update(UpdateDashboardRequest(id: "inbox-count", count: false))
        XCTAssertNil(api.list().first?.count)
        XCTAssertEqual(api.list().first?.showsCount, false)
    }

    func testCreatingTwiceFromTheSameTitleGivesDistinctIds() throws {
        let api = makeAPI()
        let a = try api.create(CreateDashboardRequest(title: "Board", script: countScript))
        let b = try api.create(CreateDashboardRequest(title: "Board", script: countScript))
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertThrowsError(try api.create(CreateDashboardRequest(id: a.id, title: "Board", script: countScript)))
        XCTAssertThrowsError(try api.create(CreateDashboardRequest(title: "x", icon: "bad icon", script: countScript)))
        XCTAssertThrowsError(try api.create(CreateDashboardRequest(title: "x", script: "no export")))
    }

    // S5
    func testAButtonThatPromptsSendsTheTextToTheChat() async throws {
        let sent = Sent()
        let api = makeAPI(sources: .init(prompt: { text, dashboard in sent.items.append((text, dashboard)) }))
        let script = "export default { view() { return Column([Button({ label: 'Ask', onClick: { prompt: 'Look at ironpet#376' } })]); } };"
        try api.create(CreateDashboardRequest(title: "Work", capabilities: .init(prompt: true), script: script))
        let view = try await api.view("work")
        let action = try XCTUnwrap(view.root?.children?.first?.action)
        var result = try await api.click(DashboardClickRequest(id: "work", handler: action))
        XCTAssertNotNil(result.error, "not approved yet")
        XCTAssertTrue(sent.items.isEmpty)
        try api.approve("work")
        result = try await api.click(DashboardClickRequest(id: "work", handler: action))
        XCTAssertNil(result.error)
        XCTAssertEqual(sent.items.first?.0, "Look at ironpet#376")
        XCTAssertEqual(sent.items.first?.1, "work")
        XCTAssertEqual(result.effects, [.init(kind: "chat")])
    }

    func testAClickThatChangesDataUpdatesStorage() async throws {
        let api = makeAPI()
        let script = "export default { view(ctx) { return Column([Text(String(ctx.data.n ?? 0)), Button({ label: '+', onClick: () => ironpet.setData({ n: (ironpet.data.n ?? 0) + 1 }) })]); } };"
        try api.create(CreateDashboardRequest(title: "Counter", script: script))
        let view = try await api.view("counter")
        _ = try await api.click(DashboardClickRequest(id: "counter", handler: try XCTUnwrap(view.root?.children?.last?.action)))
        _ = try await api.click(DashboardClickRequest(id: "counter", handler: try XCTUnwrap(view.root?.children?.last?.action)))
        XCTAssertEqual(api.store.data("counter")["n"] as? Int, 2)
        let after = try await api.view("counter")
        XCTAssertEqual(after.root?.children?.first?.text, "2")
    }

    func testAFailingScriptShowsItsReasonInsteadOfThrowing() async throws {
        let api = makeAPI()
        try api.create(CreateDashboardRequest(title: "Broken", script: "export default { view() { throw new Error('boom'); } };"))
        let view = try await api.view("broken")
        XCTAssertNil(view.root)
        XCTAssertTrue(view.error?.contains("boom") == true, "\(String(describing: view.error))")
    }

    // S6
    func testAPostToStorageIsPublishedSoAnOpenDashboardRefreshes() throws {
        let bus = APIEventBus()
        let store = makeStore()
        store.events = bus
        let api = makeAPI(store)
        try api.create(CreateDashboardRequest(title: "Board", script: countScript))
        var seen: [APIEvent] = []
        let subscription = bus.subscribe { seen.append($0) }
        var changes = 0
        let token = api.changes.observe { changes += 1 }
        try api.post(id: "board", patch: ["count": 9])
        XCTAssertEqual(seen.filter { $0.kind == .dashboardsChanged && $0.id == "board" }.count, 1)
        XCTAssertGreaterThan(changes, 0)
        subscription.cancel()
        withExtendedLifetime(token) {}
    }

    // S9
    func testDeletingRemovesTheIconTheStorageAndRefusesLaterPosts() throws {
        let api = makeAPI()
        try api.create(CreateDashboardRequest(title: "Board", capabilities: .init(prompt: true), script: countScript))
        try api.approve("board")
        try api.post(id: "board", patch: ["count": 2])
        let folder = api.store.paths.folder("board")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("storage.json").path))
        try api.delete("board")
        XCTAssertTrue(api.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertThrowsError(try api.post(id: "board", patch: ["count": 3])) { error in
            XCTAssertEqual((error as? APIError)?.code, .notFound)
        }
        XCTAssertThrowsError(try api.post(DashboardPostRequest(id: "board", data: "{\"count\":3}")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a refused post must not recreate the folder")
        // A new dashboard with the same id does not inherit the old approval.
        try api.create(CreateDashboardRequest(id: "board", title: "Board", capabilities: .init(prompt: true), script: countScript))
        XCTAssertEqual(api.store.allowed("board"), [])
    }

    func testChangingTheIconNeverAsksForApproval() throws {
        let api = makeAPI()
        try api.create(CreateDashboardRequest(title: "Board", icon: "chart.bar", script: countScript))
        try api.setAppearance(id: "board", icon: "tray", color: "orange")
        XCTAssertEqual(api.list().first?.icon, "tray")
        XCTAssertEqual(api.list().first?.color, "orange")
        XCTAssertThrowsError(try api.setAppearance(id: "board", icon: "bad icon", color: nil))
        XCTAssertThrowsError(try api.setAppearance(id: "board", icon: nil, color: "mauve"))
    }

    // MARK: The pet's tools

    // S1 and S7
    func testThePetCreatesADashboardAndReadsItsData() async throws {
        let api = makeAPI()
        let created = DashboardMCP.call("dashboards_create", [
            "title": "Inbox count", "icon": "tray", "count": true, "script": countScript,
        ], api: api)
        guard case .success(let value) = created, let object = value as? [String: Any] else { return XCTFail("\(created)") }
        XCTAssertEqual(object["id"] as? String, "inbox-count")
        XCTAssertNil(object["note"], "no capabilities, nothing to approve")
        XCTAssertEqual(api.list().map(\.title), ["Inbox count"])
        _ = DashboardMCP.call("dashboards_post", ["id": "inbox-count", "data": ["count": 3, "items": ["a", "b", "c"]]], api: api)
        guard case .success(let one) = DashboardMCP.call("dashboards_data", ["id": "inbox-count"], api: api),
              let single = one as? [String: Any], let data = single["data"] as? [String: Any] else { return XCTFail() }
        XCTAssertEqual(data["count"] as? Int, 3)
        guard case .success(let all) = DashboardMCP.call("dashboards_data", [:], api: api), let list = all as? [[String: Any]] else { return XCTFail() }
        XCTAssertEqual(list.map { $0["id"] as? String }, ["inbox-count"])
        XCTAssertEqual((list.first?["data"] as? [String: Any])?["items"] as? [String], ["a", "b", "c"])
        let view = try await api.view("inbox-count")
        XCTAssertEqual(view.root?.children?.first?.value, "3", "opening the dashboard shows the count the data holds")
    }

    func testThePetIsToldWhenACapabilityWaitsForTheUser() throws {
        let api = makeAPI()
        guard case .success(let value) = DashboardMCP.call("dashboards_create", [
            "title": "Work", "script": countScript, "capabilities": ["run": ["gh pr list"]],
        ], api: api), let object = value as? [String: Any] else { return XCTFail() }
        XCTAssertEqual(object["approval"] as? String, "pending")
        XCTAssertNotNil(object["note"])
        XCTAssertEqual(api.list().first?.capabilities.map(\.kind), ["run"])
        XCTAssertEqual(api.list().first?.capabilities.first?.isNew, false, "a new dashboard has no New tags")
        try api.approve("work")
        guard case .success = DashboardMCP.call("dashboards_update", ["id": "work", "capabilities": ["run": ["gh pr list"], "prompt": true]], api: api) else { return XCTFail() }
        XCTAssertEqual(api.list().first?.approval, "pending")
        XCTAssertEqual(api.list().first?.capabilities.map { "\($0.kind):\($0.isNew)" }, ["run:false", "prompt:true"])
    }

    func testToolsRejectBadInput() {
        let api = makeAPI()
        for args: [String: Any] in [["title": "x"], ["script": "x"], ["title": "x", "script": countScript, "capabilities": ["read": ["passwords"]]],
                                    ["title": "x", "script": countScript, "capabilities": ["network": ["not a host"]]]] {
            guard case .failure = DashboardMCP.call("dashboards_create", args, api: api) else { return XCTFail("\(args)") }
        }
        XCTAssertTrue(api.list().isEmpty)
        XCTAssertTrue(MCPEndpoint.tools.contains { $0["name"] as? String == "dashboards_create" })
        XCTAssertEqual(DashboardMCP.names, Set(DashboardMCP.tools.compactMap { $0["name"] as? String }))
    }

    // MARK: Phone routes

    func testThePhoneListsViewsAndChangesTheIconButNeverApproves() async throws {
        let rig = try ContractRig()
        let remote = RemoteDashboards(api: rig.api)
        _ = try rig.api.dashboards.create(CreateDashboardRequest(id: "work", title: "Work", icon: "briefcase", count: true, script: countScript))
        let listed = remote.list()["dashboards"] as? [[String: Any]]
        XCTAssertEqual(listed?.first?["id"] as? String, "work")
        XCTAssertEqual(listed?.first?["icon"] as? String, "briefcase")
        let view = try await remote.view("work")
        XCTAssertNotNil(view["root"])
        let changed = try remote.setAppearance("work", ["icon": "hammer", "color": "teal"])
        XCTAssertEqual(changed["icon"] as? String, "hammer")
        XCTAssertEqual(changed["color"] as? String, "teal")
        XCTAssertThrowsError(try remote.setAppearance("work", [:]))
        XCTAssertThrowsError(try remote.setAppearance("missing", ["icon": "star"]))
        do { _ = try await remote.click("work", [:]); XCTFail("a click needs a handler") } catch {}
    }

    func testADeletedDashboardRefusesAutomationPosts() async throws {
        let rig = try ContractRig()
        _ = try rig.api.dashboards.create(CreateDashboardRequest(id: "feed", title: "Feed", script: countScript))
        try rig.api.dashboards.post(id: "feed", patch: ["count": 4])
        XCTAssertTrue(try rig.api.dashboards.data("feed").data.contains("4"))
        try rig.api.dashboards.delete("feed")
        XCTAssertThrowsError(try rig.api.dashboards.post(id: "feed", patch: ["count": 5]))
        XCTAssertTrue(rig.api.dashboards.list().isEmpty)
    }
}

private final class Counter { var value = 0 }
private final class Sent { var items: [(String, String)] = [] }
