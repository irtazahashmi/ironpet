import IronPetKit
import XCTest
@testable import IronPetRemote

/// Task edits made without the Mac wait on the phone and land on the Mac once when it is back. Each test builds a model on the same
/// store twice, once with a client that cannot connect and once with one that can, which stands for a relaunch.
@MainActor
final class TaskOfflineSyncTests: XCTestCase {
    var server: MockIronPetServer!
    var store: MemoryTaskSyncStore!

    override func setUpWithError() throws {
        server = MockIronPetServer(suggestions: [])
        try server.start()
        server.taskFilters = [QuickFilter(id: "f-1", name: "Mine", query: .object(["status": .string("needs_you")]), order: 0)]
        store = MemoryTaskSyncStore()
    }

    override func tearDown() { server.stop() }

    private var online: IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) }
    /// Nothing listens on port 9, so every request fails to connect, as it does when the Mac is out of reach.
    private var offline: IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:9")!), token: server.token) }

    private func model(_ client: IronPetClient) -> TasksModel {
        TasksModel(client: client, defaults: UserDefaults(suiteName: "ironpet-task-offline-\(UUID().uuidString)")!, store: store, onUnauthorized: {})
    }

    /// A model that has read the Mac once, then a relaunch without the Mac.
    private func offlineAfterOneLoad() async -> TasksModel {
        let first = model(online)
        await first.reload()
        return model(offline)
    }

    private func changes(for id: String) -> [MockIronPetServer.Recorded] {
        server.requests.filter { ($0.json["client_id"] as? String) == id }
    }

    // S1
    func testARelaunchWithoutTheMacShowsTheLastListAndFilters() async {
        let first = model(online)
        await first.reload()
        XCTAssertFalse(first.tasks.isEmpty)
        XCTAssertEqual(first.filters.map(\.id), ["f-1"])

        let second = model(offline)
        XCTAssertEqual(second.tasks, first.tasks, "the list is there before any request")
        XCTAssertEqual(second.filters.map(\.id), ["f-1"])
        XCTAssertTrue(second.loaded)
        await second.reload()
        XCTAssertEqual(second.tasks, first.tasks, "a failed read keeps the list")
        XCTAssertEqual(second.filters.map(\.id), ["f-1"])
    }

    // S2
    func testEveryKindOfEditShowsAtOnceWithoutTheMac() async throws {
        let phone = await offlineAfterOneLoad()
        let target = try XCTUnwrap(phone.tasks.first { $0.status == .backlog })
        let other = try XCTUnwrap(phone.tasks.first { $0.status == .needsYou })

        let created = await phone.create(title: "Buy oat milk", notes: "two cartons")
        XCTAssertTrue(created)
        let local = try XCTUnwrap(phone.tasks.first { $0.title == "Buy oat milk" })
        XCTAssertEqual(local.notes, "two cartons")
        XCTAssertTrue(phone.isPendingSync(local.id))

        let moved = await phone.setStatus(target.id, status: .inProgress, note: "started")
        XCTAssertTrue(moved)
        XCTAssertEqual(phone.tasks.first { $0.id == target.id }?.status, .inProgress)

        let edited = await phone.edit(target.id, title: "Renamed offline", notes: "new notes")
        XCTAssertTrue(edited)
        XCTAssertEqual(phone.tasks.first { $0.id == target.id }?.title, "Renamed offline")
        XCTAssertEqual(phone.tasks.first { $0.id == target.id }?.notes, "new notes")

        let closed = await phone.close(other.id, note: "finished")
        XCTAssertTrue(closed)
        XCTAssertEqual(phone.tasks.first { $0.id == other.id }?.status, .done)

        XCTAssertEqual(phone.pendingSyncIDs, [local.id, target.id, other.id])
        XCTAssertFalse(phone.isPendingSync("t-untouched"))
        XCTAssertEqual(phone.pendingOps.count, 4)
        XCTAssertTrue(server.requests.filter { $0.method != "GET" }.isEmpty, "nothing reached the Mac")
    }

    // S3
    func testQueuedEditsLandOnTheMacOnceAndInOrderAndAReplayAddsNothing() async throws {
        let phone = await offlineAfterOneLoad()
        let target = try XCTUnwrap(phone.tasks.first { $0.status == .backlog })
        _ = await phone.create(title: "Buy oat milk")
        _ = await phone.setStatus(target.id, status: .inProgress, note: "started")
        _ = await phone.edit(target.id, title: "Renamed offline", notes: target.notes)
        let ids = phone.pendingOps.map { $0.id.uuidString }
        XCTAssertEqual(ids.count, 3)

        // The app is killed and the Mac is back.
        let back = model(online)
        XCTAssertEqual(back.pendingOps.map { $0.id.uuidString }, ids, "the queue survived the relaunch")
        await back.flush()
        XCTAssertTrue(back.pendingOps.isEmpty)
        for id in ids { XCTAssertEqual(changes(for: id).count, 1, "change \(id) reached the Mac once") }
        let order = server.requests.compactMap { $0.json["client_id"] as? String }
        XCTAssertEqual(order, ids, "in the order they were made")
        XCTAssertEqual(server.tasks.filter { $0.title == "Buy oat milk" }.count, 1)
        XCTAssertEqual(server.tasks.first { $0.id == target.id }?.title, "Renamed offline")
        XCTAssertEqual(server.tasks.first { $0.id == target.id }?.status, .inProgress)
        XCTAssertFalse(back.tasks.contains { TaskOp.isLocal($0.id) }, "the local id was replaced by the Mac's")

        await back.flush()
        XCTAssertEqual(server.requests.compactMap { $0.json["client_id"] as? String }.count, 3, "a second flush sends nothing")
    }

    func testAChangeTheMacAppliedBeforeTheAnswerWasLostIsNotAppliedTwice() async throws {
        let phone = await offlineAfterOneLoad()
        _ = await phone.create(title: "Call the dentist")
        let op = try XCTUnwrap(phone.pendingOps.first)
        // The first send reached the Mac, and the phone never saw the answer.
        _ = try await online.createTask(title: "Call the dentist", clientID: op.id.uuidString)
        XCTAssertEqual(server.tasks.filter { $0.title == "Call the dentist" }.count, 1)

        let back = model(online)
        await back.flush()
        XCTAssertEqual(server.tasks.filter { $0.title == "Call the dentist" }.count, 1, "the replay created nothing")
        XCTAssertEqual(changes(for: op.id.uuidString).count, 2, "it was sent twice, and applied once")
        XCTAssertTrue(back.pendingOps.isEmpty)
        XCTAssertEqual(back.tasks.filter { $0.title == "Call the dentist" }.count, 1)
    }

    func testAnUnreachableMacKeepsTheQueueAndALaterFlushSendsIt() async throws {
        let phone = await offlineAfterOneLoad()
        let target = try XCTUnwrap(phone.tasks.first { $0.status == .backlog })
        _ = await phone.setStatus(target.id, status: .needsYou, note: "")
        server.brokenRoutes = ["/v1/tasks/\(target.id)": 503]
        let relay = model(online)
        await relay.flush()
        XCTAssertEqual(relay.pendingOps.count, 1, "a 503 from the relay leaves the change waiting")
        server.brokenRoutes = [:]
        await relay.flush()
        XCTAssertTrue(relay.pendingOps.isEmpty)
        XCTAssertEqual(server.tasks.first { $0.id == target.id }?.status, .needsYou)
    }

    // S4
    func testTheMacsNewerValueWinsForTheFieldItChanged() async throws {
        let phone = await offlineAfterOneLoad()
        let target = try XCTUnwrap(phone.tasks.first { $0.status == .backlog })
        _ = await phone.edit(target.id, title: "Phone title", notes: "Phone notes")

        // Meanwhile the Mac renames the task.
        let index = try XCTUnwrap(server.tasks.firstIndex { $0.id == target.id })
        var tasks = server.tasks
        tasks[index].title = "Mac title"
        tasks[index].updated = target.updated.addingTimeInterval(600)
        server.tasks = tasks

        let back = model(online)
        await back.flush()
        let mac = try XCTUnwrap(server.tasks.first { $0.id == target.id })
        XCTAssertEqual(mac.title, "Mac title", "the Mac's title was not overwritten")
        XCTAssertEqual(mac.notes, "Phone notes", "the field the Mac did not change still lands")
        XCTAssertEqual(back.tasks.first { $0.id == target.id }?.title, "Mac title", "the phone shows the Mac's title")
        XCTAssertTrue(back.pendingOps.isEmpty)
    }

    func testAChangeToAFieldTheMacChangedIsDroppedWholeWhenNothingIsLeft() async throws {
        let phone = await offlineAfterOneLoad()
        let target = try XCTUnwrap(phone.tasks.first { $0.status == .backlog })
        _ = await phone.close(target.id, note: "done on the phone")

        let index = try XCTUnwrap(server.tasks.firstIndex { $0.id == target.id })
        var tasks = server.tasks
        tasks[index].status = .inProgress
        tasks[index].updated = target.updated.addingTimeInterval(600)
        server.tasks = tasks

        let back = model(online)
        await back.flush()
        XCTAssertEqual(server.tasks.first { $0.id == target.id }?.status, .inProgress, "the Mac's status stands")
        XCTAssertEqual(back.tasks.first { $0.id == target.id }?.status, .inProgress)
        XCTAssertTrue(back.pendingOps.isEmpty)
        XCTAssertNil(back.errorMessage, "a conflict is not an error")
    }

    // S5
    func testTheQueueIsSavedAndASecondRelaunchStillHasIt() async throws {
        let phone = await offlineAfterOneLoad()
        let target = try XCTUnwrap(phone.tasks.first { $0.status == .backlog })
        _ = await phone.setStatus(target.id, status: .done, note: "x")
        XCTAssertEqual(store.ops.count, 1)

        let stillOffline = model(offline)
        XCTAssertEqual(stillOffline.pendingOps.count, 1)
        XCTAssertEqual(stillOffline.tasks.first { $0.id == target.id }?.status, .done, "the change shows after the relaunch")
        await stillOffline.flush()
        XCTAssertEqual(stillOffline.pendingOps.count, 1, "an unreachable Mac keeps it")

        let back = model(online)
        await back.flush()
        XCTAssertTrue(store.ops.isEmpty)
        XCTAssertEqual(server.tasks.first { $0.id == target.id }?.status, .done)
    }

    func testAChangeTheMacRefusesIsUndoneWithItsReason() async throws {
        let phone = await offlineAfterOneLoad()
        let target = try XCTUnwrap(phone.tasks.first { $0.status == .backlog })
        _ = await phone.close(target.id, note: "")
        let back = model(online)
        await back.flush()
        XCTAssertTrue(back.pendingOps.isEmpty)
        XCTAssertNotNil(back.errorMessage)
        XCTAssertEqual(back.tasks.first { $0.id == target.id }?.status, .backlog)
    }

    // S6
    func testOnlineChangesGoThroughAtOnceAndLeaveNothingWaiting() async throws {
        let phone = model(online)
        await phone.reload()
        let target = try XCTUnwrap(phone.tasks.first { $0.status == .backlog })
        let done = await phone.setStatus(target.id, status: .inProgress, note: "go")
        XCTAssertTrue(done)
        XCTAssertTrue(phone.pendingOps.isEmpty)
        XCTAssertEqual(phone.tasks.first { $0.id == target.id }?.status, .inProgress)
        XCTAssertEqual(server.tasks.first { $0.id == target.id }?.status, .inProgress)
        let created = await phone.create(title: "Online task")
        XCTAssertTrue(created)
        XCTAssertTrue(phone.pendingOps.isEmpty)
        XCTAssertEqual(phone.tasks.filter { $0.title == "Online task" }.count, 1)
        XCTAssertFalse(phone.tasks.contains { TaskOp.isLocal($0.id) })
    }

    func testTheFileStoreRoundTripsAndAnUnpairDeletesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-tasksync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = FileTaskSyncStore.forToken("ipt_one", folder: folder)
        let task = RemoteTask(id: "t-1", title: "Saved", updated: Date(timeIntervalSince1970: 1_700_000_100))
        files.saveSnapshot(TaskSnapshot(tasks: [task], filters: [], filtersSupported: false))
        var op = TaskOp.make(.edit, on: task, now: Date(timeIntervalSince1970: 1_700_000_200))
        op.title = "New"
        files.saveOps([op])
        let again = FileTaskSyncStore.forToken("ipt_one", folder: folder)
        XCTAssertEqual(again.loadSnapshot()?.tasks, [task])
        XCTAssertEqual(again.loadSnapshot()?.filtersSupported, false)
        XCTAssertEqual(again.loadOps(), [op])

        let other = FileTaskSyncStore.forToken("ipt_two", folder: folder)
        XCTAssertNil(other.loadSnapshot(), "a new pairing starts empty")
        XCTAssertNil(again.loadSnapshot(), "and the earlier pairing's files are gone")

        other.saveOps([op])
        FileTaskSyncStore.clearAll(folder: folder)
        XCTAssertTrue(other.loadOps().isEmpty)
    }
}
