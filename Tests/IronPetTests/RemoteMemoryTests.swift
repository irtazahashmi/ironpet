import XCTest
@testable import IronPet
@testable import IronPetCore

/// The Memory routes of the remote API over a real listener and a temp store with invented pages: list, chips, search, page, pin, forget,
/// and the same pairing auth as every other route.
@MainActor
final class RemoteMemoryTests: XCTestCase {
    private var h: RemoteServerHarness!
    private var token = ""
    private var store: EntityMemoryStore!
    private var savedStore: EntityMemoryStore!
    private var savedLive: MemoryAPI?
    private var savedExport: URL!
    private var savedLegacy: URL!
    private var lighthouse: MemoryEntity!
    private var maya: MemoryEntity!

    private var project: ProjectKey {
        ProjectKey(key: "git.example.test/lighthouse", name: "Lighthouse", isRepo: true, workspace: URL(fileURLWithPath: "/tmp/lighthouse"))
    }

    override func setUp() async throws {
        TestMemory.isolate()
        savedExport = EntityMemoryStore.exportDirectory
        savedLegacy = LegacyMemoryFiles.directory
        savedStore = EntityMemoryStore.shared
        savedLive = MemoryAPI.live
        store = EntityMemoryStore(database: APITestSupport.memoryDatabase())
        EntityMemoryStore.shared = store
        _ = store.remember("Works from Lisbon.", scope: .me, source: "chat:a")
        _ = store.remember("Database migrations are one-way.", scope: .project, project: project, source: "chat:a")
        _ = store.remember("CI size limit is 64 MB.", scope: .project, project: project, source: "screen")
        _ = store.remember("Owns the Lighthouse repository.", scope: .people, person: "Maya Chen", source: "tasks")
        _ = store.remember("Reviews every release build.", scope: .people, person: "Maya Chen", source: "chat:b")
        lighthouse = store.entities().first { $0.name == "Lighthouse" }
        maya = store.entities().first { $0.name == "Maya Chen" }
        store.link(from: maya.id, to: lighthouse.id, type: "works_on", source: "chat:a")
        h = RemoteServerHarness()
        h.api.attach(memory: { nil })
        try await h.start()
        h.api.settings.update { $0.remote.enabled = true; $0.remote.port = h.port }
        await h.controller.settled()
        token = try await h.pairDevice().token
    }

    override func tearDown() async throws {
        await h.stop()
        EntityMemoryStore.shared = savedStore
        MemoryAPI.live = savedLive
        EntityMemoryStore.exportDirectory = savedExport
        LegacyMemoryFiles.directory = savedLegacy
    }

    private func get(_ path: String) async throws -> RemoteReply { try await h.request("GET", path, token: token) }

    // S7
    func testTheListFiltersAndSearchesWithTheMacsRule() async throws {
        let all = try await get("/v1/memory")
        XCTAssertEqual(all.status, 200)
        let pages = try XCTUnwrap(all.json["pages"] as? [[String: Any]])
        XCTAssertEqual(Set(pages.compactMap { $0["name"] as? String }), ["About me", "Lighthouse", "Maya Chen"])
        XCTAssertEqual(all.json["count_label"] as? String, "3 pages")
        XCTAssertEqual(pages.first { $0["name"] as? String == "Lighthouse" }?["fact_count"] as? Int, 2)
        XCTAssertEqual((pages.first?["id"] as? String)?.hasPrefix("page_"), true)

        let people = try await get("/v1/memory?filter=people&q=MAYA")
        XCTAssertEqual((people.json["pages"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["Maya Chen"])
        XCTAssertEqual(people.json["count_label"] as? String, "1 of 1 people")

        let none = try await get("/v1/memory?filter=projects&q=maya")
        XCTAssertEqual((none.json["pages"] as? [Any])?.count, 0)
        XCTAssertEqual((none.json["other_matches"] as? [String: Int])?["people"], 1)
        let s1 = try await get("/v1/memory?filter=nonsense").status
        XCTAssertEqual(s1, 400)
    }

    func testAPageHasFactsEarlierAndLinksAndAFollowedLinkOpensTheNextPage() async throws {
        let page = try await get("/v1/memory/pages/\(lighthouse.ref)")
        XCTAssertEqual(page.status, 200)
        XCTAssertEqual(page.json["title"] as? String, "Lighthouse")
        XCTAssertEqual((page.json["facts"] as? [[String: Any]])?.count, 2)
        let groups = try XCTUnwrap(page.json["link_groups"] as? [[String: Any]])
        XCTAssertEqual(groups.first?["title"] as? String, "Worked on by")
        let link = try XCTUnwrap((groups.first?["links"] as? [[String: Any]])?.first)
        let next = try await get("/v1/memory/pages/\(try XCTUnwrap(link["id"] as? String))")
        XCTAssertEqual(next.json["title"] as? String, "Maya Chen")
        let s2 = try await get("/v1/memory/pages/page_nope").status
        XCTAssertEqual(s2, 404)
    }

    // S5 over the remote API
    func testPinAndForgetChangeTheStore() async throws {
        let facts = store.claims(of: lighthouse.id)
        let first = try XCTUnwrap(facts.first)
        let pinned = try await h.request("POST", "/v1/memory/facts/\(first.ref)/pin", token: token, body: ["pinned": true])
        XCTAssertEqual(pinned.status, 200)
        XCTAssertTrue(try XCTUnwrap(store.claim(ref: first.ref)).pinned)
        let s3 = try await h.request("POST", "/v1/memory/facts/\(first.ref)/pin", token: token, body: [:]).status
        XCTAssertEqual(s3, 400)

        let s4 = try await h.request("DELETE", "/v1/memory/facts/\(first.ref)", token: token).status
        XCTAssertEqual(s4, 200)
        XCTAssertNil(store.claim(ref: first.ref))
        let s5 = try await h.request("DELETE", "/v1/memory/facts/\(first.ref)", token: token).status
        XCTAssertEqual(s5, 404)

        let s6 = try await h.request("DELETE", "/v1/memory/pages/\(lighthouse.ref)", token: token).status
        XCTAssertEqual(s6, 200)
        XCTAssertTrue(store.claims(of: lighthouse.id).isEmpty)
        let list = try await get("/v1/memory")
        XCTAssertFalse((list.json["pages"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "Lighthouse" })
    }

    func testNoTokenIsRefused() async throws {
        let s7 = try await h.request("GET", "/v1/memory").status
        XCTAssertEqual(s7, 401)
        let s8 = try await h.request("DELETE", "/v1/memory/pages/\(lighthouse.ref)").status
        XCTAssertEqual(s8, 401)
        XCTAssertFalse(store.claims(of: lighthouse.id).isEmpty)
    }
}
