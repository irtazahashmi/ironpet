import Foundation
import XCTest
import IronPetKit
@testable import IronPetCore

/// The error shapes of docs/protocol.md. The golden file `errors.json` covers the errors a real method raises. These tests cover
/// the ones no method can raise with in-memory stores, the lines that are not requests, and the envelope itself.
@MainActor
final class ContractErrorTests: XCTestCase {
    private func response(_ line: String, _ rig: ContractRig) async throws -> JSONRPCResponse {
        try JSONDecoder().decode(JSONRPCResponse.self, from: await rig.dispatcher.handle(line: Data(line.utf8)))
    }

    func testALineThatIsNotJSONIsAParseErrorWithANullID() async throws {
        let reply = try await response("not json", try ContractRig())
        XCTAssertEqual(reply.id, .null)
        XCTAssertEqual(reply.error?.code, -32700)
        XCTAssertNil(reply.result)
    }

    func testJSONThatIsNotARequestIsAnInvalidRequest() async throws {
        let rig = try ContractRig()
        let noMethod = try await response(#"{"jsonrpc":"2.0","id":4}"#, rig)
        XCTAssertEqual(noMethod.id, .null)
        XCTAssertEqual(noMethod.error?.code, -32600)
        let oldVersion = try await response(#"{"jsonrpc":"1.0","id":5,"method":"tasks.list"}"#, rig)
        XCTAssertEqual(oldVersion.id, .int(5))
        XCTAssertEqual(oldVersion.error?.code, -32600)
    }

    func testAStringIDComesBackUnchanged() async throws {
        let reply = try await response(#"{"jsonrpc":"2.0","id":"req-9","method":"alerts.list"}"#, try ContractRig())
        XCTAssertEqual(reply.id, .string("req-9"))
        XCTAssertEqual(reply.result, .array([]))
    }

    /// Each `APIError.Code` has its own JSON-RPC code, and `data.code` keeps the name a client branches on.
    func testEveryAPIErrorCaseKeepsItsCodeMessageAndData() async throws {
        let rig = try ContractRig()
        var seen: Set<Int> = []
        for code in APIError.Code.allCases {
            rig.dispatcher.register(RPCMethod(name: "test.raise", route: "none", params: "none", result: "null") { _ in
                throw APIError(code: code, message: "raised \(code.rawValue)")
            })
            let reply = try await response(#"{"jsonrpc":"2.0","id":1,"method":"test.raise"}"#, rig)
            let error = try XCTUnwrap(reply.error, "\(code)")
            XCTAssertEqual(error.code, RPCDispatcher.code(for: code))
            XCTAssertEqual(error.message, "raised \(code.rawValue)")
            XCTAssertEqual(error.data, .object(["code": .string(code.rawValue)]))
            XCTAssertTrue((-32099 ... -32000).contains(error.code), "\(code) must sit in the range JSON-RPC leaves to the server")
            seen.insert(error.code)
        }
        XCTAssertEqual(seen.count, APIError.Code.allCases.count, "two APIError cases share a JSON-RPC code")
    }

    func testAnErrorThatIsNotAnAPIErrorBecomesFailed() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "the disk is full" } }
        let rig = try ContractRig()
        rig.dispatcher.register(RPCMethod(name: "test.raise", route: "none", params: "none", result: "null") { _ in throw Boom() })
        let reply = try await response(#"{"jsonrpc":"2.0","id":1,"method":"test.raise"}"#, rig)
        let error = try XCTUnwrap(reply.error)
        XCTAssertEqual(error.code, RPCDispatcher.code(for: .failed))
        XCTAssertEqual(error.message, "the disk is full")
        XCTAssertEqual(error.data, .object(["code": .string("failed")]))
    }

    func testMemoryIsUnavailableUntilItIsAttached() async throws {
        let rig = try ContractRig()
        let line = #"{"jsonrpc":"2.0","id":1,"method":"memory.call","params":{"name":"memory_search","arguments":{"query":"x"}}}"#
        let reply = try await response(line, rig)
        let error = try XCTUnwrap(reply.error)
        XCTAssertEqual(error.code, RPCDispatcher.code(for: .unavailable))
        XCTAssertEqual(error.data, .object(["code": .string("unavailable")]))
    }

    // MARK: Envelope

    func testASuccessWithNothingToReturnKeepsItsNullResult() async throws {
        let data = RPCDispatcher.encode(JSONRPCResponse(id: .int(1), result: .null))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"id":1,"jsonrpc":"2.0","result":null}"#)
        let back = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        XCTAssertEqual(back.result, .null)
        XCTAssertNil(back.error)
    }

    func testAnErrorResponseHasNoResultMember() async throws {
        let data = RPCDispatcher.encode(JSONRPCResponse(id: .string("a"), error: JSONRPCError(code: -32601, message: "no method")))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"error":{"code":-32601,"message":"no method"},"id":"a","jsonrpc":"2.0"}"#)
    }

    func testEveryEventKindBecomesANotificationNamedAfterIt() async throws {
        let at = ContractRig.epoch
        for kind in APIEventKind.allCases {
            let note = RPCDispatcher.notification(for: APIEvent(seq: 7, at: at, kind: kind, id: "abc"))
            XCTAssertEqual(note.method, kind.rawValue)
            XCTAssertEqual(note.params, .object(["seq": .int(7), "at": .string("2026-11-06T21:20:00Z"), "id": .string("abc")]))
        }
        let bare = RPCDispatcher.notification(for: APIEvent(seq: 8, at: at, kind: .tasksChanged, id: nil))
        XCTAssertEqual(bare.params, .object(["seq": .int(8), "at": .string("2026-11-06T21:20:00Z")]))
        let line = String(decoding: RPCDispatcher.encode(bare), as: UTF8.self)
        XCTAssertEqual(line, #"{"jsonrpc":"2.0","method":"tasks.changed","params":{"at":"2026-11-06T21:20:00Z","seq":8}}"#)
    }
}
