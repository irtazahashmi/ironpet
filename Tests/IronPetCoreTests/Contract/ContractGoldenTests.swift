import Foundation
import XCTest
import IronPetKit
@testable import IronPetCore

/// Runs every file in `Contract/Fixtures` against the in-process API. Each case is one request line through
/// `RPCDispatcher.handle(line:)`, the path a stdio client takes, and the response must equal the golden one.
///
/// A deliberate API change makes these fail. Review the diff, then run `UPDATE_GOLDENS=1 swift test --filter Contract` to rewrite the
/// responses, and commit the new files with `docs/protocol.md`.
@MainActor
final class ContractGoldenTests: XCTestCase {
    private var updating: Bool { ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1" }

    func testEveryGoldenFileMatchesTheAPI() async throws {
        let names = try ContractFiles.fixtureNames()
        XCTAssertGreaterThanOrEqual(names.count, 8, "one file per facade: inbox, alerts, agents, automations, chat, memory, settings, today")
        for name in names { try await run(name) }
    }

    func testEveryRequiredFacadeHasAReadAndAWrite() async throws {
        let reads: [String: Set<String>] = [
            "inbox": ["inbox.list"], "alerts": ["alerts.list", "alerts.get"], "agents": ["agents.list", "agents.get"],
            "automations": ["automations.list", "automations.get"], "chat": ["chat.status", "chat.messages"],
            "memory": ["memory.call"], "settings": ["settings.get"], "today": ["today.brief"],
        ]
        let writes: [String: Set<String>] = [
            "inbox": ["inbox.add", "inbox.done", "inbox.remove", "inbox.resolve"], "alerts": ["alerts.dismiss"], "agents": ["agents.acknowledge"],
            "automations": ["automations.create", "automations.setEnabled"], "chat": ["chat.send", "chat.setMode"],
            "memory": ["memory.call"], "settings": ["settings.patch"], "today": ["today.brief"],
        ]
        for facade in reads.keys.sorted() {
            let file = try loadFile("\(facade).json")
            let used = Set(file.cases.compactMap { (testCase: GoldenFile.Case) -> String? in
                guard case .object(let fields) = testCase.request, case .string(let method)? = fields["method"] else { return nil }
                return method
            })
            XCTAssertFalse(used.isDisjoint(with: reads[facade]!), "\(facade).json has no read method from \(reads[facade]!.sorted())")
            XCTAssertFalse(used.isDisjoint(with: writes[facade]!), "\(facade).json has no write method from \(writes[facade]!.sorted())")
        }
    }

    /// S4: a golden file that disagrees with the API fails, and the message names the method and the field.
    func testARenamedFieldIsReportedWithTheMethodAndTheField() async throws {
        var file = try loadFile("inbox.json")
        guard let index = file.cases.firstIndex(where: { Self.method(of: $0) == "inbox.list" && $0.name == "list after add" }),
              case .object(var response) = file.cases[index].response, case .array(var items)? = response["result"],
              case .object(var item)? = items.first, let title = item.removeValue(forKey: "title")
        else { return XCTFail("inbox.json needs an inbox.list case named \"list after add\" with a title in its first item") }
        item["name"] = title
        items[0] = .object(item)
        response["result"] = .array(items)
        file.cases[index].response = .object(response)

        let failures = try await failures(of: file)
        let message = try XCTUnwrap(failures.first)
        XCTAssertTrue(message.contains("inbox.list"), message)
        XCTAssertTrue(message.contains("response.result[0].name"), message)
        XCTAssertTrue(message.contains(#""title""#), message)
    }

    func testTheDifferenceNamesTheFieldInsideAList() async throws {
        let golden = RemoteJSON.object(["result": .array([.object(["id": .string("a"), "title": .string("One")])])])
        let actual = RemoteJSON.object(["result": .array([.object(["id": .string("a"), "title": .string("Two")])])])
        XCTAssertEqual(GoldenJSON.difference(golden: golden, actual: actual),
                       #"response.result[0].title: the golden file has "One" and the API sent "Two""#)
    }

    // MARK: Running

    private static func method(of testCase: GoldenFile.Case) -> String {
        guard case .object(let fields) = testCase.request, case .string(let method)? = fields["method"] else { return "?" }
        return method
    }

    private func loadFile(_ name: String) throws -> GoldenFile {
        try JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: ContractFiles.fixtures.appendingPathComponent(name)))
    }

    private func failures(of file: GoldenFile) async throws -> [String] {
        let rig = try ContractRig(seed: file.seed)
        var failures: [String] = []
        for testCase in file.cases {
            let actual = try await rig.send(testCase.request, captures: testCase.capture ?? [:])
            if let difference = GoldenJSON.difference(golden: testCase.response, actual: actual) {
                failures.append("\(Self.method(of: testCase)) (\(testCase.name)): \(difference)")
            }
        }
        return failures
    }

    private func run(_ name: String) async throws {
        var file = try loadFile(name)
        if updating {
            let rig = try ContractRig(seed: file.seed)
            for index in file.cases.indices {
                file.cases[index].response = try await rig.send(file.cases[index].request, captures: file.cases[index].capture ?? [:])
            }
            try GoldenJSON.encoder().encode(file).write(to: ContractFiles.fixtures.appendingPathComponent(name))
            return
        }
        for message in try await failures(of: file) { XCTFail("\(name): \(message)") }
    }
}
