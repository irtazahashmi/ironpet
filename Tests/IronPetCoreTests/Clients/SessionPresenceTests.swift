import XCTest
@testable import IronPetCore

/// The idle time AutomationEngine and WelcomeBack read comes from `lastInputAt` on the sessions. The Mac's own idle, lock and wake keep
/// working through its adapter.
@MainActor
final class SessionPresenceTests: XCTestCase {
    private final class Adapter: PresenceSource {
        var idle: TimeInterval? = 30
        var locked = false
        var woke = false
        var stops = 0
        nonisolated var isSupported: Bool { true }
        func idleSeconds() throws -> TimeInterval {
            guard let idle else { throw CapabilityError.unsupported(capability: "PresenceSource", platform: "test") }
            return idle
        }
        func isScreenLocked() -> Bool { locked }
        func wokeSince(_ date: Date) -> Bool { woke }
        func micCalls() -> Set<String> { ["zoom.us"] }
        func stopMicWatch() { stops += 1 }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheLocalIdleTimeComesBackThroughTheSession() throws {
        let clients = ClientRegistry(now: { self.now })
        let session = clients.registerLocal(name: "Mac", kind: .mac, capabilities: [.presence])
        let adapter = Adapter()
        let presence = SessionPresence(registry: clients, local: adapter, now: { self.now })
        XCTAssertEqual(try presence.idleSeconds(), 30)
        XCTAssertEqual(clients.session(session.id)?.lastInputAt, now.addingTimeInterval(-30))
        adapter.idle = 400
        XCTAssertEqual(try presence.idleSeconds(), 400, "the adapter's newer answer replaces the stored one, even when it is larger")
        XCTAssertEqual(presence.idleOrZero(), 400)
    }

    func testTheMostRecentDesktopInputWinsAndAPhoneDoesNotCount() throws {
        let clients = ClientRegistry(now: { self.now })
        clients.registerLocal(name: "Mac", kind: .mac, capabilities: [.presence])
        let windows = clients.connect(deviceID: "pc", name: "PC", kind: .windows, capabilities: [.presence], connection: .remote)
        let phone = clients.connect(deviceID: "phone", name: "Phone", kind: .ios, connection: .remote)
        clients.recordInput(windows.id, at: now.addingTimeInterval(-5))
        clients.recordInput(phone.id, at: now.addingTimeInterval(-1))
        let presence = SessionPresence(registry: clients, local: Adapter(), now: { self.now })
        XCTAssertEqual(try presence.idleSeconds(), 5, "the PC was used 5 s ago, the Mac 30 s ago")
    }

    func testWithNoReportingClientTheUserCountsAsAtTheKeyboard() {
        let clients = ClientRegistry(now: { self.now })
        let adapter = Adapter()
        adapter.idle = nil
        clients.registerLocal(name: "Mac", kind: .mac, capabilities: [.presence])
        let presence = SessionPresence(registry: clients, local: adapter, now: { self.now })
        XCTAssertThrowsError(try presence.idleSeconds()) { XCTAssertTrue($0 is CapabilityError) }
        XCTAssertEqual(presence.idleOrZero(), 0)
    }

    func testALocalClientWithoutThePresenceCapabilityIsNotAsked() {
        let clients = ClientRegistry(now: { self.now })
        clients.registerLocal(name: "Mac", kind: .mac, capabilities: [])
        let presence = SessionPresence(registry: clients, local: Adapter(), now: { self.now })
        XCTAssertEqual(presence.idleOrZero(), 0)
    }

    func testLockWakeAndMicrophoneStayWithTheMachine() {
        let clients = ClientRegistry(now: { self.now })
        let adapter = Adapter()
        adapter.locked = true
        adapter.woke = true
        let presence = SessionPresence(registry: clients, local: adapter, now: { self.now })
        XCTAssertTrue(presence.isScreenLocked())
        XCTAssertTrue(presence.wokeSince(now))
        XCTAssertEqual(presence.micCalls(), ["zoom.us"])
        presence.stopMicWatch()
        XCTAssertEqual(adapter.stops, 1)
    }
}
