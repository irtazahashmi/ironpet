import XCTest
import IronPetKit
@testable import IronPetCore

/// S4 beyond the golden files: what `session.hello` does to the registry, and the wire shape of the capability error.
@MainActor
final class SessionHelloTests: XCTestCase {
    private func hello(protocolVersion: Int = 1, lastSeq: Int? = nil) -> HelloRequest {
        HelloRequest(protocolVersion: protocolVersion, client: ClientInfo(name: "ironpet-ios", version: "1.4.0"), lastSeq: lastSeq)
    }

    func testHelloOpensASessionOnAConnectionThatHasNone() throws {
        let rig = try ContractRig()
        let connection = RPCConnection(deviceID: "cli-1", name: "CLI", kind: .cli, connection: .inProcess)
        let result = try rig.api.session.hello(hello(), connection: connection)
        XCTAssertEqual(connection.sessionID, result.session)
        let session = try XCTUnwrap(rig.api.clients.session(result.session))
        XCTAssertEqual(session.deviceID, "cli-1")
        XCTAssertEqual(session.kind, .cli)
        XCTAssertEqual(session.client, ClientInfo(name: "ironpet-ios", version: "1.4.0"))
    }

    func testHelloNamesTheClientInTheSessionTheTransportOpened() throws {
        let rig = try ContractRig()
        let phone = rig.api.clients.connect(deviceID: "phone-1", name: "iPhone", kind: .ios, connection: .remote)
        let connection = RPCConnection(deviceID: "phone-1", name: "iPhone", kind: .ios, connection: .remote, sessionID: phone.id)
        let result = try rig.api.session.hello(hello(), connection: connection)
        XCTAssertEqual(result.session, phone.id)
        XCTAssertEqual(rig.api.clients.sessions.count, 1, "hello must not make a second session")
        XCTAssertEqual(rig.api.clients.session(phone.id)?.client?.name, "ironpet-ios")
    }

    func testGapIsTrueOnlyWhenEventsWereLost() throws {
        let events = APIEventBus(capacity: 3)
        let clients = ClientRegistry()
        let session = SessionAPI(clients: clients, events: events) { ["tasks"] }
        let connection = RPCConnection(deviceID: "d", name: "n", kind: .cli, connection: .inProcess)
        for _ in 0..<5 { events.publish(.tasksChanged) }
        XCTAssertFalse(try session.hello(hello(lastSeq: 5), connection: connection).gap, "the client has seen everything")
        XCTAssertFalse(try session.hello(hello(lastSeq: 2), connection: connection).gap, "events 3 to 5 are still held")
        XCTAssertTrue(try session.hello(hello(lastSeq: 1), connection: connection).gap, "event 2 is gone")
        XCTAssertFalse(try session.hello(hello(lastSeq: nil), connection: connection).gap, "a first connection has nothing to miss")
        XCTAssertEqual(try session.hello(hello(), connection: connection).seq, 5)
    }

    func testAnUnknownProtocolIsInvalidInSwiftToo() throws {
        let rig = try ContractRig()
        let connection = RPCConnection(deviceID: "d", name: "n", kind: .cli, connection: .inProcess)
        XCTAssertThrowsError(try rig.api.session.hello(hello(protocolVersion: 7), connection: connection)) {
            XCTAssertEqual(($0 as? APIError)?.code, .invalid)
        }
        XCTAssertEqual(rig.api.clients.sessions, [], "a refused hello opens nothing")
    }

    func testHelloOverATransportWithNoConnectionIsUnavailable() async throws {
        let rig = try ContractRig()
        let line = Data(#"{"jsonrpc":"2.0","id":1,"method":"session.hello","params":{"protocol":1,"client":{"name":"x","version":"1"}}}"#.utf8)
        let reply = try JSONDecoder().decode(JSONRPCResponse.self, from: await rig.dispatcher.handle(line: line))
        XCTAssertEqual(reply.error?.code, RPCDispatcher.code(for: .unavailable))
        XCTAssertEqual(rig.api.clients.sessions, [])
    }

    func testAConnectionLimitedToHelloCannotReachAnyOtherMethod() async throws {
        let rig = try ContractRig()
        let connection = RPCConnection(deviceID: "d", name: "n", kind: .ios, connection: .remote)
        let tasks = Data(#"{"jsonrpc":"2.0","id":1,"method":"tasks.list","params":{"includeDone":false}}"#.utf8)
        let reply = try JSONDecoder().decode(JSONRPCResponse.self, from: await rig.dispatcher.handle(line: tasks, connection: connection, allowed: ["session.hello"]))
        XCTAssertEqual(reply.error?.code, JSONRPCError.methodNotFound)
        let allowed = Data(#"{"jsonrpc":"2.0","id":2,"method":"session.hello","params":{"protocol":1,"client":{"name":"x","version":"1"}}}"#.utf8)
        let ok = try JSONDecoder().decode(JSONRPCResponse.self, from: await rig.dispatcher.handle(line: allowed, connection: connection, allowed: ["session.hello"]))
        XCTAssertNil(ok.error)
        XCTAssertNotNil(connection.sessionID)
    }

    func testACapabilityErrorKeepsItsFieldsOnTheWire() async throws {
        let rig = try ContractRig()
        rig.dispatcher.register(RPCMethod(name: "test.raise", route: "none", params: "none", result: "null") { _ in
            throw CapabilityError.unsupported(capability: "screen", platform: "iOS")
        })
        let reply = try JSONDecoder().decode(JSONRPCResponse.self, from: await rig.dispatcher.handle(line: Data(#"{"jsonrpc":"2.0","id":1,"method":"test.raise"}"#.utf8)))
        XCTAssertEqual(reply.error?.code, -32006)
        XCTAssertEqual(reply.error?.data, .object(["code": .string("unsupported"), "capability": .string("screen"), "platform": .string("iOS")]))
        XCTAssertEqual(reply.error?.message, "screen is not available on iOS")
    }

    func testTheChatOriginCarriesTheDeviceAndOldOnesStillDecode() throws {
        let origin = ChatOrigin.ios(device: "phone-1")
        XCTAssertEqual(origin.device, "phone-1")
        XCTAssertEqual(origin.ref, "phone-1")
        let decoded = try JSONDecoder().decode(ChatOrigin.self, from: JSONEncoder().encode(origin))
        XCTAssertEqual(decoded, origin)
        let old = try JSONDecoder().decode(ChatOrigin.self, from: Data(#"{"client":"telegram","ref":"42"}"#.utf8))
        XCTAssertNil(old.device)
        XCTAssertEqual(ChatOrigin.telegram(chat: 42).device, nil)
    }
}
