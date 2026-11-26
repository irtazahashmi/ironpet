import XCTest
import IronPetKit
@testable import IronPetCore

/// The public ids of captures, meetings, notifications, chats and messages: how they are minted, kept, and read by `get`.
@MainActor
final class RecordKindRefsTests: XCTestCase {
    private func freshRefs() -> RecordRefs {
        RecordRefs(database: Database.open(path: nil, migrations: AppMigrations.all).database)
    }

    /// The Kit's link prefixes are the kinds of record: a new kind must be added to both.
    func testTheLinkPrefixesAreTheRecordKinds() {
        XCTAssertEqual(RecordLinks.prefixes, RecordKind.allCases.map(\.rawValue))
    }

    func testAdoptKeepsTheFirstRefForAKey() async throws {
        let refs = freshRefs()
        XCTAssertEqual(refs.adopt("meeting_abc123", .meeting, "2026-11-18-1000"), "meeting_abc123")
        XCTAssertEqual(refs.adopt("meeting_fff999", .meeting, "2026-11-18-1000"), "meeting_abc123", "the stored ref wins")
        let minted = try XCTUnwrap(refs.adopt("task_abc123", .meeting, "2026-11-18-1100"))
        XCTAssertTrue(minted.hasPrefix("meeting_"), "a ref of another kind is refused, and the key gets its own ref")
    }

    func testBatchRefsAreDistinctAndStable() async throws {
        let refs = freshRefs()
        let keys = (0..<1200).map { "msg-\($0)" }
        let first = refs.refs(.msg, keys)
        XCTAssertEqual(first.count, keys.count)
        XCTAssertEqual(Set(first.values).count, keys.count, "every message gets its own ref")
        XCTAssertEqual(refs.refs(.msg, keys), first, "a second read returns the same refs")
    }

    func testAMeetingKeepsItsRefInTheFolderAfterTheDatabaseIsRebuilt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetings-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("2026-11-18-1000")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try XCTUnwrap(MeetingIdentity.ref(folder: folder, records: freshRefs()))
        XCTAssertTrue(first.hasPrefix("meeting_"))
        let marker = try String(contentsOf: folder.appendingPathComponent(MeetingIdentity.markerName), encoding: .utf8)
        XCTAssertEqual(marker.trimmingCharacters(in: .whitespacesAndNewlines), first)

        // A new database knows nothing of the meeting; the marker brings the same id back.
        XCTAssertEqual(MeetingIdentity.ref(folder: folder, records: freshRefs()), first)
    }

    func testANotificationIsReadByGetWithItsRef() async throws {
        let database = Database.open(path: nil, migrations: AppMigrations.all).database
        let store = NotificationStore(database: database)
        let api = NotificationsAPI(store: store)
        let item = try XCTUnwrap(store.add(NotificationDraft(source: "mail", type: .reminder, title: "Hi", description: "Body", links: [])))
        let ref = try XCTUnwrap(api.refs([item.id])[item.id])
        XCTAssertTrue(ref.hasPrefix("notif_"))

        let readers = RecordReaders.make(screen: { nil }, notifications: { api }, meetings: { nil }, chat: { nil })
        let resolver = RecordResolver(refs: RecordRefs(database: database), readers: readers)
        let found = try XCTUnwrap(resolver.resolve(ref).resultValue)
        let reading = await resolver.read(found)
        let read = try XCTUnwrap(reading?.resultValue)
        XCTAssertEqual(read["ref"] as? String, ref)
        XCTAssertEqual(read["kind"] as? String, "notif")
        XCTAssertEqual(read["title"] as? String, "Hi")
    }

    func testGetReadsANotificationThroughTheMCPEndpoint() async throws {
        let database = Database.open(path: nil, migrations: AppMigrations.all).database
        let store = NotificationStore(database: database)
        let api = NotificationsAPI(store: store)
        let item = try XCTUnwrap(store.add(NotificationDraft(source: "mail", type: .reminder, title: "Hi", description: "Body", links: [])))
        let ref = try XCTUnwrap(api.refs([item.id])[item.id])
        let readers = RecordReaders.make(screen: { nil }, notifications: { api }, meetings: { nil }, chat: { nil })
        let resolver = RecordResolver(refs: RecordRefs(database: database), readers: readers)

        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                               "params": ["name": "get", "arguments": ["id": ref]]])
        let (status, data) = await MCPEndpoint.handle(body, automations: nil, tasks: nil, records: resolver)
        XCTAssertEqual(status, "200 OK")
        let result = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = try XCTUnwrap(((result["content"] as? [[String: Any]])?.first)?["text"] as? String)
        XCTAssertTrue(text.contains("\"ref\" : \"\(ref)\""), text)
        XCTAssertTrue(text.contains("\"title\" : \"Hi\""), text)
    }

    func testAKindWithoutAReaderIsNotReadByTheResolver() async throws {
        let database = Database.open(path: nil, migrations: AppMigrations.all).database
        let resolver = RecordResolver(refs: RecordRefs(database: database), readers: [:])
        let ref = try XCTUnwrap(RecordRefs(database: database).ref(.meeting, "2026-11-18-1000"))
        let found = try XCTUnwrap(resolver.resolve(ref).resultValue)
        let reading = await resolver.read(found)
        XCTAssertNil(reading)
    }

    func testACaptureHasItsRefInTheWindowAndInSearch() async throws {
        let store = CaptureStore(database: Database.open(path: nil, migrations: AppMigrations.all).database)
        let app = CaptureApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        guard case .stored(let id) = try store.ingest(app: app, title: "Ana", url: nil, trigger: .typingPause, lines: ["one", "two"], now: now) else {
            return XCTFail("the capture was not stored")
        }
        let ref = try XCTUnwrap(store.records.ref(.screen, String(id)))
        XCTAssertTrue(ref.hasPrefix("screen_"))

        let window = try XCTUnwrap(ScreenMCP.call("screen_window", ["id": Int(id)], store: store).resultValue as? [String: Any])
        XCTAssertEqual((window["capture"] as? [String: Any])?["ref"] as? String, ref)

        let search = try XCTUnwrap(ScreenMCP.call("screen_search", ["query": "one"], store: store).resultValue as? [String: Any])
        let hits = try XCTUnwrap(search["hits"] as? [[String: Any]])
        XCTAssertEqual(hits.first?["ref"] as? String, ref)
    }
}

private extension Result {
    var resultValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
