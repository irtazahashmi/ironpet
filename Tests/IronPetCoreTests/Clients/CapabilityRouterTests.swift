import XCTest
import IronPetKit
@testable import IronPetCore

/// S3: a server-initiated request goes only to a client that advertises the capability, and fails with
/// `CapabilityError.unsupported` when none does.
@MainActor
final class CapabilityRouterTests: XCTestCase {
    private final class Inbox {
        var requests: [ClientRequest] = []
        var reply: RemoteJSON = .string("ok")
        var handler: ClientHandler { { [self] request in requests.append(request); return reply } }
    }

    private let screenshot = ClientRequest(capability: .screen, method: "screen.capture")

    func testARequestGoesOnlyToTheClientThatAdvertisesTheCapability() async throws {
        let clients = ClientRegistry()
        let mac = Inbox(), phone = Inbox()
        let macSession = clients.connect(deviceID: "mac", name: "Mac", kind: .mac, capabilities: [.screen], connection: .inProcess, handler: mac.handler)
        clients.connect(deviceID: "phone", name: "Phone", kind: .ios, connection: .remote, handler: phone.handler)
        mac.reply = .string("png")
        let delivery = try await CapabilityRouter(registry: clients).send(screenshot)
        XCTAssertEqual(delivery, .delivered(client: macSession, reply: .string("png")))
        XCTAssertEqual(mac.requests, [screenshot])
        XCTAssertEqual(phone.requests, [], "the phone does not advertise the screen")
    }

    func testACapableClientThatIsNotADesktopLeavesNobodyToAskSoItIsUnsupported() async throws {
        let clients = ClientRegistry()
        clients.connect(deviceID: "cli", name: "CLI", kind: .cli, capabilities: [.screen], connection: .remote, handler: { _ in .null })
        do {
            _ = try await CapabilityRouter(registry: clients).send(screenshot)
            XCTFail("no desktop can take the request")
        } catch let error as CapabilityError {
            XCTAssertEqual(error, .unsupported(capability: "screen", platform: PlatformName.current))
        }
    }

    func testNoClientWithTheCapabilityFailsWithUnsupportedAndNamesThePlatform() async throws {
        let clients = ClientRegistry()
        let phone = Inbox()
        clients.connect(deviceID: "phone", name: "Phone", kind: .ios, connection: .remote, handler: phone.handler)
        do {
            _ = try await CapabilityRouter(registry: clients).send(screenshot, origin: .ios(device: "phone"))
            XCTFail("nothing can take a screenshot")
        } catch let error as CapabilityError {
            XCTAssertEqual(error, .unsupported(capability: "screen", platform: "iOS"))
        }
        XCTAssertEqual(phone.requests, [])
        do {
            _ = try await CapabilityRouter(registry: ClientRegistry()).send(ClientRequest(capability: .desktop, method: "desktop.press"))
            XCTFail("nobody is connected")
        } catch let error as CapabilityError {
            XCTAssertEqual(error, .unsupported(capability: "desktop", platform: PlatformName.current))
        }
    }

    func testTheOriginDeviceGetsTheRequestBeforeAMoreRecentOne() async throws {
        let clients = ClientRegistry()
        let laptop = Inbox(), desk = Inbox()
        clients.connect(deviceID: "laptop", name: "Laptop", kind: .windows, capabilities: [.desktop], connection: .remote, handler: laptop.handler)
        let deskSession = clients.connect(deviceID: "desk", name: "Desk", kind: .mac, capabilities: [.desktop], connection: .remote, handler: desk.handler)
        clients.recordInput(deskSession.id, at: Date().addingTimeInterval(60))
        let press = ClientRequest(capability: .desktop, method: "desktop.press", params: .object(["ref": .string("e1")]))
        _ = try await CapabilityRouter(registry: clients).send(press, origin: ChatOrigin(client: "windows", ref: "laptop", device: "laptop"))
        XCTAssertEqual(laptop.requests, [press])
        XCTAssertEqual(desk.requests, [])
    }

    func testTwoEquallyRecentClientsReturnTheAskResultAndNobodyIsSent() async throws {
        let clients = ClientRegistry(now: { Date(timeIntervalSince1970: 100) })
        let one = Inbox(), two = Inbox()
        clients.connect(deviceID: "one", name: "One", kind: .mac, capabilities: [.screen], connection: .remote, handler: one.handler)
        clients.connect(deviceID: "two", name: "Two", kind: .windows, capabilities: [.screen], connection: .remote, handler: two.handler)
        guard case .ask(let candidates) = try await CapabilityRouter(registry: clients).send(screenshot) else { return XCTFail("a tie must ask") }
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(one.requests + two.requests, [])
    }

    func testAClientWithNoWayToTakeRequestsIsUnavailableNotUnsupported() async throws {
        let clients = ClientRegistry()
        clients.connect(deviceID: "mac", name: "Mac", kind: .mac, capabilities: [.screen], connection: .inProcess)
        do {
            _ = try await CapabilityRouter(registry: clients).send(screenshot)
            XCTFail("the client has no handler")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .unavailable)
        }
    }

    func testADisconnectedClientIsNotAskedAgain() async throws {
        let clients = ClientRegistry()
        let mac = Inbox()
        let session = clients.connect(deviceID: "mac", name: "Mac", kind: .mac, capabilities: [.screen], connection: .remote, handler: mac.handler)
        clients.disconnect(session.id)
        do {
            _ = try await CapabilityRouter(registry: clients).send(screenshot)
            XCTFail("the only screen is gone")
        } catch is CapabilityError {}
        XCTAssertEqual(mac.requests, [])
    }
}
