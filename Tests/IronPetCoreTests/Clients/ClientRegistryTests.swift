import XCTest
import IronPetKit
@testable import IronPetCore

/// S1 and S2: sessions start and end with their connection, the local client's capabilities follow the platform, and "my screen"
/// resolves to the origin device, else the most recently active desktop client, else asks.
@MainActor
final class ClientRegistryTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var counter = 0

    private func registry() -> ClientRegistry {
        ClientRegistry(now: { [unowned self] in clock }, newID: { [unowned self] in counter += 1; return "s\(counter)" })
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    func testAPhoneConnectingMakesASessionAndDisconnectingRemovesIt() async {
        let clients = registry()
        let phone = clients.connect(deviceID: "phone-1", name: "Ana's iPhone", kind: .ios, connection: .remote)
        XCTAssertEqual(clients.sessions, [phone])
        XCTAssertEqual(phone.deviceID, "phone-1")
        XCTAssertEqual(phone.kind, .ios)
        XCTAssertEqual(phone.connection, .remote)
        XCTAssertEqual(clients.sessions(forDevice: "phone-1").map(\.id), [phone.id])
        XCTAssertEqual(clients.disconnect(phone.id), phone)
        XCTAssertEqual(clients.sessions, [])
        XCTAssertNil(clients.disconnect(phone.id), "a second disconnect finds nothing")
    }

    func testTheSameDeviceConnectingTwiceHasTwoSessions() async {
        let clients = registry()
        let first = clients.connect(deviceID: "phone-1", name: "iPhone", kind: .ios, connection: .remote)
        let second = clients.connect(deviceID: "phone-1", name: "iPhone", kind: .ios, connection: .remote)
        XCTAssertNotEqual(first.id, second.id)
        clients.disconnect(first.id)
        XCTAssertEqual(clients.sessions.map(\.id), [second.id])
    }

    func testTheLocalClientIsRegisteredOnceAndItsCapabilitiesAreUpdated() async {
        let clients = registry()
        let first = clients.registerLocal(name: "Mac", kind: .mac, capabilities: [.presence])
        XCTAssertEqual(first.deviceID, ClientRegistry.localDeviceID)
        XCTAssertEqual(first.connection, .inProcess)
        let second = clients.registerLocal(name: "Mac", kind: .mac, capabilities: [.screen, .presence, .screen])
        XCTAssertEqual(second.id, first.id, "screen capture starts later and must not make a second session")
        XCTAssertEqual(clients.sessions.count, 1)
        XCTAssertEqual(clients.local?.capabilities, [.presence, .screen], "sorted and without duplicates")
    }

    func testCapabilitiesAreOneForEachRealAdapter() async {
        XCTAssertEqual(Platform.unsupported.clientCapabilities(), [])
        XCTAssertEqual(Platform.unsupported.clientCapabilities(extra: [.desktop]), [.desktop])
        let names = Set(Platform.unsupported.capabilities.map(\.name))
        XCTAssertEqual(names.subtracting(Platform.capabilityForAdapter.keys), [], "a new adapter needs a capability name in Platform.capabilityForAdapter")
        XCTAssertEqual(Set(Platform.capabilityForAdapter.keys).subtracting(names), [], "a capability name for an adapter that is gone")
    }

    func testASessionEncodesAsPlainJSON() async throws {
        let session = ClientSession(id: "s1", deviceID: "d1", name: "Mac", kind: .mac, capabilities: [.screen, .desktop], lastInputAt: at(5),
                                    connectedAt: at(0), subscriptions: ["tasks.changed"], connection: .inProcess)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(session), as: UTF8.self)
        XCTAssertEqual(json, #"{"capabilities":["desktop","screen"],"connectedAt":"2027-01-15T08:00:00Z","connection":"inProcess","deviceID":"d1","id":"s1","kind":"mac","lastInputAt":"2027-01-15T08:00:05Z","name":"Mac","subscriptions":["tasks.changed"]}"#)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ClientSession.self, from: Data(json.utf8)), session)
    }

    func testInputNeverMovesBackwards() async {
        let clients = registry()
        let mac = clients.connect(deviceID: "mac", name: "Mac", kind: .mac, capabilities: [.screen], connection: .inProcess)
        clients.recordInput(mac.id, at: at(10))
        clients.recordInput(mac.id, at: at(4))
        XCTAssertEqual(clients.session(mac.id)?.lastInputAt, at(10))
    }

    // MARK: My screen (S2)

    func testMyScreenIsTheOriginDeviceWhenItHasAScreen() async {
        let clients = registry()
        let laptop = clients.connect(deviceID: "laptop", name: "Laptop", kind: .windows, capabilities: [.screen], connection: .remote)
        let desk = clients.connect(deviceID: "desk", name: "Desk", kind: .mac, capabilities: [.screen], connection: .remote)
        clients.recordInput(desk.id, at: at(100))
        let origin = ChatOrigin(client: "windows", ref: "laptop", device: "laptop")
        XCTAssertEqual(clients.resolveScreen(origin: origin), .client(clients.session(laptop.id)!), "the origin wins over the more recent desk")
    }

    func testMyScreenIsTheMostRecentlyActiveDesktopWhenTheOriginHasNone() async {
        let clients = registry()
        let old = clients.connect(deviceID: "old", name: "Old", kind: .mac, capabilities: [.screen], connection: .remote)
        let fresh = clients.connect(deviceID: "fresh", name: "Fresh", kind: .windows, capabilities: [.screen], connection: .remote)
        clients.connect(deviceID: "phone", name: "Phone", kind: .ios, connection: .remote)
        clients.recordInput(old.id, at: at(10))
        clients.recordInput(fresh.id, at: at(50))
        let phone = ChatOrigin.ios(device: "phone")
        XCTAssertEqual(clients.resolveScreen(origin: phone), .client(clients.session(fresh.id)!), "a phone has no screen to read")
        XCTAssertEqual(clients.resolveScreen(origin: nil), .client(clients.session(fresh.id)!), "the Mac's own input box has no origin")
    }

    func testAClientThatNeverTypedCountsFromWhenItConnected() async {
        let clients = registry()
        let early = clients.connect(deviceID: "early", name: "Early", kind: .mac, capabilities: [.screen], connection: .remote)
        clock = at(60)
        let late = clients.connect(deviceID: "late", name: "Late", kind: .mac, capabilities: [.screen], connection: .remote)
        XCTAssertEqual(clients.resolveScreen(), .client(clients.session(late.id)!))
        clients.recordInput(early.id, at: at(90))
        XCTAssertEqual(clients.resolveScreen(), .client(clients.session(early.id)!))
    }

    func testMyScreenAsksWhenNoDesktopCanBeUsed() async {
        let clients = registry()
        XCTAssertEqual(clients.resolveScreen(), .ask(candidates: []))
        clients.connect(deviceID: "phone", name: "Phone", kind: .ios, connection: .remote)
        XCTAssertEqual(clients.resolveScreen(origin: .ios(device: "phone")), .ask(candidates: []))
        clients.connect(deviceID: "bare", name: "No capture", kind: .mac, capabilities: [.presence], connection: .remote)
        XCTAssertEqual(clients.resolveScreen(), .ask(candidates: []), "a desktop that cannot capture is not a candidate")
    }

    func testMyScreenAsksInsteadOfPickingBetweenTwoEquallyRecentDesktops() async {
        let clients = registry()
        let one = clients.connect(deviceID: "one", name: "One", kind: .mac, capabilities: [.screen], connection: .remote)
        let two = clients.connect(deviceID: "two", name: "Two", kind: .windows, capabilities: [.screen], connection: .remote)
        clients.recordInput(one.id, at: at(30))
        clients.recordInput(two.id, at: at(30))
        guard case .ask(let candidates) = clients.resolveScreen() else { return XCTFail("a tie must ask") }
        XCTAssertEqual(Set(candidates.map(\.id)), [one.id, two.id])
    }
}
