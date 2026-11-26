import XCTest
@testable import IronPet
@testable import IronPetCore
import enum IronPetKit.BuiltInQuickFilters
import struct IronPetKit.QuickFilter
import enum IronPetKit.QuickFilterNode
import enum IronPetKit.RemoteJSON

@MainActor
final class NextActionsTests: XCTestCase {
    private var api: TasksAPI!

    override func setUp() {
        api = TasksAPI(store: TaskStore(database: APITestSupport.memoryDatabase(), keepDoneDays: { 30 }))
    }

    @discardableResult
    private func add(_ title: String, _ status: TaskStatus = .backlog, waitingOn: String? = nil, labels: [String: String] = [:]) throws -> TaskItem {
        try api.create(CreateTaskRequest(title: title, status: status, source: .user, waitingOn: waitingOn, labels: labels))
    }

    private var nextActionsNode: QuickFilterNode? {
        BuiltInQuickFilters.all.first { $0.id == BuiltInQuickFilters.nextActionsID }?.node
    }

    func testTheContextLabelAcceptsTheSixValuesOnlyAndIgnoresCase() throws {
        XCTAssertEqual(try TaskValidator.labels(["context": " Mac "]), ["context": "mac"])
        XCTAssertEqual(try TaskValidator.labels(["context": "PHONE"]), ["context": "phone"])
        XCTAssertThrowsError(try TaskValidator.labels(["context": "office"])) { error in
            XCTAssertTrue((error as? TaskError)?.message.contains("context must be one of mac, phone") ?? false)
        }
        XCTAssertEqual(try TaskValidator.labels(["area": "office"]), ["area": "office"], "other keys take any value")
    }

    func testAnUnknownContextReadsAsNone() {
        XCTAssertEqual(TaskContext.of(["context": "errands"]), .errands)
        XCTAssertNil(TaskContext.of(["context": "office"]))
        XCTAssertNil(TaskContext.of([:]))
    }

    func testAreaFallsBackToTheProjectLabelOnOlderTasks() throws {
        XCTAssertEqual(try add("Old", labels: ["project": "epic"]).areaLabel, "epic")
        XCTAssertEqual(try add("Both", labels: ["project": "old", "area": "new"]).areaLabel, "new")
        XCTAssertNil(try add("None").areaLabel)
    }

    func testTheGroupsFollowTheContextOrderAndNoContextComesLast() throws {
        let phone = try add("Call the bank", labels: ["context": "phone"])
        let mac = try add("Fix login", labels: ["context": "mac"])
        let home = try add("Water plants", labels: ["context": "home"])
        let none = try add("Buy stamps")
        let area = try add("Email", labels: ["area": "x"])
        let macToo = try add("Read PR", labels: ["context": "mac"])

        let groups = NextActions.groups([phone, none, mac, home, area, macToo])
        XCTAssertEqual(groups.map(\.title), ["Mac", "Phone", "Home", "No context"])
        XCTAssertEqual(groups.map { $0.tasks.map(\.title) }, [["Fix login", "Read PR"], ["Call the bank"], ["Water plants"], ["Buy stamps", "Email"]],
                       "each group keeps the order it came in")
    }

    func testNoGroupsWhenThereAreNoTasks() {
        XCTAssertTrue(NextActions.groups([]).isEmpty)
    }

    func testNextActionsShowsOpenTasksNobodyHoldsAndLeavesOutDoneAndWaitingOnes() throws {
        try add("Open")
        try add("Needs me", .needsYou)
        try add("Doing", .inProgress)
        try add("Held", waitingOn: "Ana")
        try add("Finished", .done)

        let node = try XCTUnwrap(nextActionsNode)
        XCTAssertEqual(Set(api.all.filter { node.matches($0) }.map(\.title)), ["Open", "Needs me", "Doing"])
    }

    func testTheBuiltInChipIsNotStoredAndItsNameAndIdAreReserved() throws {
        XCTAssertTrue(api.quickFilters.isEmpty, "the built-in chip lives in code, not in config.json")
        XCTAssertThrowsError(try api.upsertQuickFilter(id: nil, name: "Next actions", query: ["status": "needs_you"]))
        XCTAssertThrowsError(try api.upsertQuickFilter(id: nil, name: "next ACTIONS", query: ["status": "needs_you"]))
        XCTAssertThrowsError(try api.upsertQuickFilter(id: "next-actions", name: "Mine", query: ["status": "needs_you"]))

        let saved = try api.upsertQuickFilter(id: nil, name: "Next-actions", query: ["status": "needs_you"])
        XCTAssertNotEqual(saved.id, BuiltInQuickFilters.nextActionsID, "a generated id skips the built-in one")
    }

    func testOnlyTheBuiltInChipGroupsByContext() {
        XCTAssertTrue(api.groupsByContext(BuiltInQuickFilters.nextActionsID))
        XCTAssertFalse(api.groupsByContext(nil), "All lists by status")
        XCTAssertFalse(api.groupsByContext("epic"))
    }

    func testAgentsAndTheCLICanListNextActions() throws {
        try add("Open")
        try add("Finished", .done)
        let text = String(describing: try TaskJSON.call(api, "list", ["filter": BuiltInQuickFilters.nextActionsID], by: "agent:mcp").get())
        XCTAssertTrue(text.contains("Open"))
        XCTAssertFalse(text.contains("Finished"))
    }

    func testAFilterSavedEarlierWithTheBuiltInIdKeepsWorkingAndCanBeEdited() throws {
        let query = try JSONDecoder().decode(RemoteJSON.self, from: Data(#"{"status":"needs_you"}"#.utf8))
        api.setQuickFilterStorage([QuickFilter(id: BuiltInQuickFilters.nextActionsID, name: "Next actions", query: query)])

        XCTAssertTrue(api.builtInQuickFilters.isEmpty, "the built-in chip steps aside instead of showing a second chip with the same id")
        XCTAssertEqual(api.quickFilter(BuiltInQuickFilters.nextActionsID)?.query, query, "the saved query is the one applied")
        XCTAssertFalse(api.groupsByContext(BuiltInQuickFilters.nextActionsID), "the saved filter lists plainly, without context groups")

        let edited = try api.upsertQuickFilter(id: BuiltInQuickFilters.nextActionsID, name: "Next actions", query: ["status": "backlog"])
        XCTAssertEqual(edited.name, "Next actions", "an edit may keep the name it already had")
        XCTAssertThrowsError(try api.upsertQuickFilter(id: nil, name: "Next actions", query: ["status": "backlog"]), "a new filter still cannot take it")
    }

    func testTheBuiltInChipCannotBeRemovedOrMoved() {
        XCTAssertThrowsError(try api.deleteQuickFilter(BuiltInQuickFilters.nextActionsID))
        XCTAssertThrowsError(try api.reorderQuickFilters([BuiltInQuickFilters.nextActionsID]))
        XCTAssertThrowsError(try api.moveQuickFilter(BuiltInQuickFilters.nextActionsID, by: 1))
        XCTAssertEqual(api.builtInQuickFilters.map(\.id), [BuiltInQuickFilters.nextActionsID])
    }

    func testAgentsCannotFileATaskWithAnUnknownContext() {
        let args: [String: Any] = ["title": "Fix the printer", "labels": ["context": "office"],
                                   "origin": ["kind": "chat", "ref": "t1", "reason": "asked"]]
        guard case .failure(let error) = TaskJSON.call(api, "create", args, by: "agent:mcp") else { return XCTFail("an unknown context is refused") }
        XCTAssertTrue(error.message.contains("context must be one of"))
    }

    func testAContextStoredBeforeTheCheckIsReadWhateverItsCase() {
        XCTAssertEqual(TaskContext.of(["context": " Mac "]), .mac)
    }

    func testSettingTheContextAddsAndRemovesTheLabel() throws {
        let task = try add("Pay rent")
        _ = try TaskEdits.setContext(.errands, of: task.id, in: api)
        XCTAssertEqual(api.task(task.id)?.labels["context"], "errands")
        _ = try TaskEdits.setContext(nil, of: task.id, in: api)
        XCTAssertNil(api.task(task.id)?.labels["context"])
    }
}
