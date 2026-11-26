import XCTest
@testable import IronPet
@testable import IronPetCore

/// `get` for the kinds whose ref the owner keeps (memory pages and claims) and for automation runs.
@MainActor
final class RecordReadersTests: XCTestCase {
    private func read(_ resolver: RecordResolver, _ id: String) async -> Result<[String: Any], RecordError>? {
        switch resolver.resolve(id) {
        case .success(let found): return await resolver.read(found)
        case .failure(let error): return .failure(error)
        }
    }

    private func object(_ result: Result<[String: Any], RecordError>?, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        guard case .success(let object)? = result else {
            XCTFail("expected a record, got \(String(describing: result))", file: file, line: line)
            return [:]
        }
        return object
    }

    private func message(_ result: Result<[String: Any], RecordError>?) -> String? {
        guard case .failure(let error)? = result else { return nil }
        return error.message
    }

    private func resolver(_ database: Database, memory: MemoryAPI? = nil, automations: AutomationsAPI? = nil) -> RecordResolver {
        RecordResolver(refs: RecordRefs(database: database), readers: RecordReaders.make(
            screen: { nil }, notifications: { nil }, meetings: { nil }, chat: { nil }, memory: { memory }, automations: { automations }))
    }

    func testAPageAndItsClaimAreReadByTheirOwnRefs() async throws {
        let database = APITestSupport.memoryDatabase()
        let store = EntityMemoryStore(database: database)
        _ = store.remember("Lives in Berlin", scope: .people, person: "Maya Chen", source: "chat:a")
        let memory = MemoryAPI(services: { nil }, pages: { store })
        let entity = try XCTUnwrap(memory.entities().first { $0.name == "Maya Chen" })
        let claim = try XCTUnwrap(memory.claims(of: entity.id).first)
        let records = resolver(database, memory: memory)

        let page = object(await read(records, entity.ref))
        XCTAssertEqual(page["kind"] as? String, "page")
        XCTAssertEqual(page["ref"] as? String, entity.ref)
        XCTAssertEqual(page["entity"] as? String, "Maya Chen", "the page reads as memory_page gives it")
        XCTAssertEqual((page["claims"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [claim.ref])

        let fact = object(await read(records, claim.ref))
        XCTAssertEqual(fact["kind"] as? String, "claim")
        XCTAssertEqual(fact["text"] as? String, "Lives in Berlin")
        XCTAssertEqual(fact["page"] as? String, entity.ref, "a claim names the page it is on")
    }

    func testAMemoryRefThatNamesNothingSaysSo() async {
        let database = APITestSupport.memoryDatabase()
        let records = resolver(database, memory: MemoryAPI(services: { nil }, pages: { EntityMemoryStore(database: database) }))
        let page = await read(records, "page_000000"), claim = await read(records, "claim_000000")
        XCTAssertEqual(message(page), "no memory page with id page_000000")
        XCTAssertNotNil(message(claim))
    }

    func testARunHasARefInItsHistoryAndGetReadsIt() async throws {
        let database = APITestSupport.memoryDatabase()
        var service: AutomationService!
        let api = APITestSupport.makeAPI(configureAutomations: {
            $0.engine.state = AutomationState(database: database)
            service = $0
        })
        service.engine.state.record("a1", .init(date: Date(timeIntervalSince1970: 1_800_000_000), outcome: "ok", output: "done"))
        let ref = try XCTUnwrap(service.history("a1", limit: 5).first?["ref"], "automations_history lists each run with its ref")
        XCTAssertTrue(ref.hasPrefix("run_"))

        let run = object(await read(resolver(database, automations: api.automations), ref))
        XCTAssertEqual(run["kind"] as? String, "run")
        XCTAssertEqual(run["automation"] as? String, "a1")
        XCTAssertEqual(run["outcome"] as? String, "ok")
        XCTAssertEqual(run["output"] as? String, "done")
        XCTAssertEqual(run["ref"] as? String, ref)
    }

    func testAPrunedRunSaysOnlyTheLastRunsAreKept() async throws {
        let database = APITestSupport.memoryDatabase()
        var service: AutomationService!
        let api = APITestSupport.makeAPI(configureAutomations: {
            $0.engine.state = AutomationState(database: database)
            service = $0
        })
        let state = service.engine.state
        state.record("a1", .init(date: Date(timeIntervalSince1970: 1_800_000_000), outcome: "ok", output: "first"))
        let first = try XCTUnwrap(service.history("a1", limit: 1).first?["ref"])
        for index in 1...AutomationState.historyLimit {
            state.record("a1", .init(date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), outcome: "ok", output: "run \(index)"))
        }
        let pruned = message(await read(resolver(database, automations: api.automations), first))
        XCTAssertEqual(pruned?.contains("only the last runs"), true, "the ref of a pruned run names nothing and says why")
    }
}
