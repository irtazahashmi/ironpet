import XCTest
#if canImport(Combine)
import Combine
#endif
@testable import IronPet

/// Each store fires its `changes` signal from `willSet`, and its facade forwards the signal. A handler runs before the value
/// changes, so each test also records what the store held when the signal fired.
@MainActor
final class ChangeSignalStoreTests: XCTestCase {
    private func alert(_ id: String) -> Signal {
        Signal(id: id, title: id, subtitle: "", url: nil, label: "CI failed", symbol: "xmark", mood: .failed)
    }

    // S3
    func testTaskStoreAndTasksAPI() throws {
        let store = TaskStore(database: APITestSupport.memoryDatabase())
        let api = TasksAPI(store: store)
        var storeCount = 0, apiCount = 0, titlesWhenFired: [Int] = []
        let a = store.changes.observe { storeCount += 1; titlesWhenFired.append(store.tasks.count) }
        let b = api.changes.observe { apiCount += 1 }
        _ = try store.create(title: "Write the report", source: .user, by: "user")
        XCTAssertGreaterThan(storeCount, 0)
        XCTAssertEqual(apiCount, storeCount, "the facade forwards every store change")
        XCTAssertEqual(titlesWhenFired.first, 0, "the signal fires before the task is in the list")
        XCTAssertEqual(api.items.count, 1)
        withExtendedLifetime((a, b)) {}
    }

    // S3
    func testConfigStoreAndSettingsAPI() {
        let store = ConfigStore(memory: Config())
        let api = SettingsAPI(store: store)
        var storeCount = 0, apiCount = 0
        var before: String?
        let a = store.changes.observe { storeCount += 1; before = before ?? store.config.window.appearance }
        let b = api.changes.observe { apiCount += 1 }
        store.update { $0.window.appearance = "dark" }
        XCTAssertEqual(storeCount, 1)
        XCTAssertEqual(apiCount, 1)
        XCTAssertNotEqual(before, "dark", "the handler ran before the new value was set")
        XCTAssertEqual(store.config.window.appearance, "dark")
        withExtendedLifetime((a, b)) {}
    }

    // S3
    func testBubbleStoreAndBubblesAPI() {
        let store = BubbleStore()
        let api = BubblesAPI(store: store)
        var storeCount = 0, apiCount = 0
        let a = store.changes.observe { storeCount += 1 }
        let b = api.changes.observe { apiCount += 1 }
        store.show(BubbleDraft(id: "one", symbol: "bell", tint: .orange, title: "Hello"))
        XCTAssertEqual([storeCount, apiCount], [1, 1])
        store.dismiss("one")
        XCTAssertEqual([storeCount, apiCount], [2, 2])
        api.setPetOnLeft(true)
        XCTAssertEqual([storeCount, apiCount], [3, 3], "petOnLeft was @Published too")
        withExtendedLifetime((a, b)) {}
    }

    // S3
    func testSignalStoreAndAlertsAPI() {
        let store = SignalStore()
        let api = AlertsAPI(store: store)
        var storeCount = 0, apiCount = 0, openWhenFired: [Int] = []
        let a = store.changes.observe { storeCount += 1; openWhenFired.append(store.signals.count) }
        let b = api.changes.observe { apiCount += 1 }
        store.add(alert("a"), notify: false)
        store.dismiss("a")
        XCTAssertEqual([storeCount, apiCount], [2, 2])
        XCTAssertEqual(openWhenFired, [0, 1])
        withExtendedLifetime((a, b)) {}
    }

    // S3
    func testNotificationStoreAndNotificationsAPI() throws {
        let store = NotificationStore(database: APITestSupport.memoryDatabase())
        let api = NotificationsAPI(store: store)
        var storeCount = 0, apiCount = 0
        let a = store.changes.observe { storeCount += 1 }
        let b = api.changes.observe { apiCount += 1 }
        let item = try XCTUnwrap(store.add(NotificationDraft(source: "mail", type: .reminder, title: "A", description: "", links: [])))
        XCTAssertGreaterThan(storeCount, 0)
        XCTAssertEqual(apiCount, storeCount)
        let before = storeCount
        store.markRead(item.id)
        XCTAssertGreaterThan(storeCount, before)
        XCTAssertEqual(apiCount, storeCount)
        withExtendedLifetime((a, b)) {}
    }

    // S3
    func testSessionStoreAndAgentsAPI() {
        let store = SessionStore()
        let api = AgentsAPI(store: store)
        var storeCount = 0, apiCount = 0
        let a = store.changes.observe { storeCount += 1 }
        let b = api.changes.observe { apiCount += 1 }
        store.apply(HookEvent(source: .claude, name: "UserPromptSubmit", payload: ["session_id": "s1"], origin: SessionOrigin()))
        XCTAssertGreaterThan(storeCount, 0)
        XCTAssertEqual(apiCount, storeCount)
        withExtendedLifetime((a, b)) {}
    }

    // S3
    func testMeetingLibraryRegeneratorAndMeetingsAPI() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-signal-\(UUID().uuidString)")
        let library = MeetingLibrary(root: root)
        let api = MeetingsAPI(controller: MeetingController(), library: library)
        var apiCount = 0
        let token = api.changes.observe { apiCount += 1 }
        var libraryCount = 0
        let libraryToken = library.changes.observe { libraryCount += 1 }
        library.reload()
        XCTAssertEqual(libraryCount, 1)
        XCTAssertEqual(apiCount, 1)
        var regeneratorCount = 0
        let regeneratorToken = library.regenerator.changes.observe { regeneratorCount += 1 }
        library.regenerator.clearPreview()
        XCTAssertEqual(regeneratorCount, 2, "activeID and progress each fire")
        XCTAssertEqual(apiCount, 3)
        withExtendedLifetime((token, libraryToken, regeneratorToken)) {}
    }

    // S3
    func testCaptureStatusModel() {
        let model = CaptureStatusModel()
        var count = 0
        let token = model.changes.observe { count += 1 }
        model.running = true
        model.captureCount = 3
        XCTAssertEqual(count, 2)
        withExtendedLifetime(token) {}
    }

    #if canImport(Combine)
    // S2, S3
    func testObservedObjectStillSeesAStoreChangeBeforeItHappens() {
        let store = TaskStore(database: APITestSupport.memoryDatabase())
        let api = TasksAPI(store: store)
        var fired = 0
        let subscription = api.objectWillChange.sink { fired += 1 }
        _ = try? store.create(title: "One", source: .user, by: "user")
        XCTAssertGreaterThan(fired, 0)
        withExtendedLifetime(subscription) {}
    }
    #endif
}
