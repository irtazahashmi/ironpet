import XCTest
#if canImport(Combine)
import Combine
#endif
@testable import IronPet
@testable import IronPetCore

/// `AutomationStore` fires `changes` before `automations` or `error` change, `AutomationsAPI` forwards it, and the digest
/// subscriber behind the pet's Today item applies a value only when it differs from the last one it applied.
@MainActor
final class AutomationChangeSignalTests: XCTestCase {
    private func makeStore(_ list: [Automation] = []) -> AutomationStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-auto-signal-\(UUID().uuidString)")
        let paths = AutomationPaths(file: dir.appendingPathComponent("automations.json"), directory: dir.appendingPathComponent("automations"))
        return AutomationStore(paths: paths, defaults: { list }, watch: false)
    }

    private func reminder(_ id: String, enabled: Bool = true) -> Automation {
        Automation(id: id, name: id, enabled: enabled, trigger: .init(type: "interval", minutes: 5, clock: "active"),
                   action: .init(type: "bubble", title: id, body: ""), createdBy: "user")
    }

    private func digest(_ id: String, enabled: Bool = true) -> Automation {
        Automation(id: id, name: id, enabled: enabled, trigger: .init(type: "daily", times: ["09:00"]),
                   action: .init(type: "digest", digest: "brief"), createdBy: "user")
    }

    // S1
    func testReplaceAndUpdateFireBeforeTheListChanges() throws {
        let store = makeStore([reminder("a")])
        let service = AutomationService(store: store, engine: AutomationEngine(env: AutomationTestClock().environment))
        let api = AutomationsAPI(service: service)
        var storeCount = 0, apiCount = 0, countWhenFired: [Int] = []
        let a = store.changes.observe { storeCount += 1; countWhenFired.append(store.automations.count) }
        let b = api.changes.observe { apiCount += 1 }
        try store.replace([reminder("a"), reminder("b")])
        XCTAssertEqual(countWhenFired, [1], "the signal fires before the new list is in place")
        XCTAssertEqual(store.automations.count, 2)
        let before = storeCount
        try store.update("b") { $0.enabled = false }
        XCTAssertGreaterThan(storeCount, before)
        XCTAssertEqual(apiCount, storeCount, "the facade forwards every store change")
        XCTAssertEqual(api.list().first { $0.id == "b" }?.enabled, false)
        withExtendedLifetime((a, b)) {}
    }

    // S1
    func testReloadFromDiskAndAFailedLoadFire() throws {
        let store = makeStore([reminder("a")])
        var count = 0, errorWhenFired: [String?] = []
        let token = store.changes.observe { count += 1; errorWhenFired.append(store.error) }
        let good = try JSONEncoder().encode(AutomationFile(automations: [reminder("a"), reminder("c")]))
        try good.write(to: store.paths.file)
        store.reload(force: true)
        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(store.automations.count, 2)
        let before = count
        try Data("{ not json".utf8).write(to: store.paths.file)
        store.reload(force: true)
        XCTAssertGreaterThan(count, before, "a failed load sets `error`")
        XCTAssertNotNil(store.error)
        XCTAssertEqual(errorWhenFired.last ?? nil, nil, "the signal fired before `error` was set")
        withExtendedLifetime(token) {}
    }

    #if canImport(Combine)
    // S2
    func testObjectWillChangeFiresOnStoreAndAPI() throws {
        let store = makeStore([reminder("a")])
        let api = AutomationsAPI(service: AutomationService(store: store, engine: AutomationEngine(env: AutomationTestClock().environment)))
        var storeFired = 0, apiFired = 0
        let one = store.objectWillChange.sink { storeFired += 1 }
        let two = api.objectWillChange.sink { apiFired += 1 }
        try api.setEnabled("a", false)
        XCTAssertGreaterThan(storeFired, 0)
        XCTAssertEqual(apiFired, storeFired)
        withExtendedLifetime((one, two)) {}
    }
    #endif

    // S3
    func testDigestShownFollowsTheToggleAndIgnoresUnrelatedChanges() async throws {
        let store = makeStore([reminder("a"), digest("brief", enabled: false)])
        var applied: [Bool] = []
        let token = store.observeDigestShown { applied.append($0) }
        XCTAssertEqual(applied, [false], "the current value is applied at once, as `$automations` emitted it")

        try store.update("brief") { $0.enabled = true }
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(applied, [false, true], "the new value lands after the change")

        try store.update("a") { $0.enabled = false }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(applied, [false, true], "an unrelated automation does not apply again")

        try store.update("brief") { $0.enabled = false }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(applied, [false, true, false])
        withExtendedLifetime(token) {}
    }
}
