import Foundation
import XCTest
import IronPetKit
@testable import IronPetCore

/// docs/protocol.md must name everything the code can send or return. Each test enumerates one source of truth and fails with the
/// names that the document is missing.
@MainActor
final class ContractDocTests: XCTestCase {
    private var doc: String { (try? String(contentsOf: ContractFiles.protocolDoc, encoding: .utf8)) ?? "" }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: ContractFiles.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func matches(_ pattern: String, in text: String) -> [[String]] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0 ..< match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    func testTheDocumentExists() async throws {
        XCTAssertFalse(doc.isEmpty, "docs/protocol.md is missing")
    }

    func testEveryEventIsDocumentedAsANotification() async throws {
        let missing = APIEventKind.allCases.map(\.rawValue).filter { !doc.contains("`\($0)`") }
        XCTAssertEqual(missing, [], "docs/protocol.md has no notification for these events")
    }

    func testEveryAPIErrorCaseIsInTheErrorTable() async throws {
        for code in APIError.Code.allCases {
            let row = doc.split(separator: "\n").first { $0.contains("`\(code.rawValue)`") && $0.contains("\(RPCDispatcher.code(for: code))") }
            XCTAssertNotNil(row, "docs/protocol.md has no error row for `\(code.rawValue)` with code \(RPCDispatcher.code(for: code))")
        }
        for code in [-32700, -32600, -32601, -32602] {
            XCTAssertTrue(doc.contains("\(code)"), "docs/protocol.md does not list the JSON-RPC code \(code)")
        }
    }

    func testEveryFacadeHasASection() async throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: ContractFiles.root.appendingPathComponent("Sources/IronPetCore/API").path)
        let facades = files.filter { $0.hasSuffix("API.swift") && $0 != "IronPetAPI.swift" }
            .map { String($0.dropLast("API.swift".count)).lowercased() }.sorted()
        XCTAssertGreaterThanOrEqual(facades.count, 17)
        let missing = facades.filter { !doc.contains("### `\($0)`") }
        XCTAssertEqual(missing, [], "docs/protocol.md has no section for these facades")
    }

    /// Every method in the table has a row with its params type, result type and REST route.
    func testEveryMethodHasARowWithItsTypesAndRoute() async throws {
        let rig = try ContractRig()
        let rows = doc.split(separator: "\n").map(String.init)
        for method in rig.dispatcher.all {
            guard let row = rows.first(where: { $0.hasPrefix("| `\(method.name)` |") }) else {
                XCTFail("docs/protocol.md has no row for `\(method.name)`")
                continue
            }
            let cells = row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(cells.count, 6, "\(method.name): a row has | method | params | result | REST route |")
            guard cells.count == 6 else { continue }
            XCTAssertEqual(cells[2], method.params == "none" ? "none" : "`\(method.params)`", "\(method.name) params")
            XCTAssertEqual(cells[3], "`\(method.result)`", "\(method.name) result")
            let routes = method.route.components(separatedBy: ", ").map { $0 == "none" ? "none" : "`\($0)`" }.joined(separator: ", ")
            XCTAssertEqual(cells[4], routes, "\(method.name) REST route")
        }
    }

    /// The methods in the document are the methods in the table, so a removed method does not stay documented.
    func testNoDocumentedMethodIsMissingFromTheTable() async throws {
        let known = Set(try ContractRig().dispatcher.all.map(\.name))
        let documented = matches(#"(?m)^\| `([a-z]+\.[A-Za-z]+)` \| (?:`[^`]+`|none) \| `[^`]+` \|"#, in: doc).map { $0[1] }
        XCTAssertEqual(Set(documented).subtracting(known).sorted(), [], "documented, but no such method in RPCDispatcher")
    }

    // MARK: REST routes

    private func serverRoutes() throws -> [(verb: String, path: String)] {
        let text = try source("Sources/IronPet/Remote/RemoteServer.swift")
        let found = matches(#"router\.(get|post|put|patch|delete|ws)\(\s*"(/v1/[^"]+)""#, in: text)
        return found.map { (verb: $0[1] == "ws" ? "GET" : $0[1].uppercased(), path: $0[2]) }
    }

    func testEveryRemoteServerRouteIsListed() async throws {
        let routes = try serverRoutes()
        XCTAssertGreaterThan(routes.count, 60)
        let missing = routes.map { "\($0.verb) \($0.path)" }.filter { !doc.contains("`\($0)`") }
        XCTAssertEqual(missing, [], "docs/protocol.md does not list these /v1 routes")
    }

    func testEveryAPIPathRouteIsListed() async throws {
        let text = try source("Sources/IronPetKit/APIPath.swift")
        let paths = matches(#""(/v1/[^"]+)""#, in: text).map { $0[1] }
        XCTAssertGreaterThan(paths.count, 60)
        let normalised = paths.map { path -> String in
            var path = path
            for match in matches(#"\\\(([A-Za-z0-9]+)\)"#, in: path) {
                path = path.replacingOccurrences(of: match[0], with: match[1] == "bubble" ? ":id" : ":" + match[1])
            }
            return path
        }
        let missing = Set(normalised).filter { !doc.contains($0) }.sorted()
        XCTAssertEqual(missing, [], "docs/protocol.md does not mention these APIPath routes")
    }

    /// A method's REST route must be a route the server registers, so the mapping column cannot name a route that is not there.
    func testEveryMethodRouteExistsOnTheServer() async throws {
        let routes = Set(try serverRoutes().map { "\($0.verb) \($0.path)" })
        for method in try ContractRig().dispatcher.all where method.route != "none" {
            for route in method.route.components(separatedBy: ", ") {
                XCTAssertTrue(routes.contains(route), "\(method.name) maps to \(route), which RemoteServer does not register")
            }
        }
    }

    // MARK: Handshake

    func testTheHandshakeIsDocumentedAndMarkedForCorePR12() async throws {
        XCTAssertTrue(doc.contains("`session.hello`"))
        XCTAssertTrue(doc.contains("core PR 12"), "the handshake must say it is implemented in core PR 12")
        XCTAssertTrue(doc.lowercased().contains("newline-delimited"), "the stdio framing must be documented")
    }

    // MARK: Clients

    func testEveryClientKindAndCapabilityIsDocumented() async throws {
        let kinds = ClientKind.allCases.map(\.rawValue).filter { !doc.contains("`\($0)`") }
        XCTAssertEqual(kinds, [], "docs/protocol.md does not name these client kinds")
        let names = Set(Platform.capabilityForAdapter.values.map(\.rawValue)).union([ClientCapability.desktop.rawValue])
        XCTAssertEqual(names.filter { !doc.contains("`\($0)`") }.sorted(), [], "docs/protocol.md does not name these client capabilities")
    }

    func testEveryClientSessionFieldIsDocumented() async throws {
        let session = ClientSession(id: "s", deviceID: "d", name: "n", kind: .mac, lastInputAt: Date(), connectedAt: Date(), connection: .inProcess,
                                    client: ClientInfo(name: "n", version: "1"))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any] ?? [:]
        XCTAssertGreaterThanOrEqual(object.count, 9, "every field of a full session")
        let missing = object.keys.sorted().filter { !doc.contains("| `\($0)` |") }
        XCTAssertEqual(missing, [], "the ClientSession table in docs/protocol.md lacks these fields")
    }
}
