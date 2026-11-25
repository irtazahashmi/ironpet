import Foundation
import IronPetKit

/// Where the contract files live. They are read from the source tree, so the tests need no bundle on any platform.
enum ContractFiles {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = root.appendingPathComponent("Tests/IronPetCoreTests/Contract/Fixtures")
    static let protocolDoc = root.appendingPathComponent("docs/protocol.md")

    static func fixtureNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtures.path).filter { $0.hasSuffix(".json") }.sorted()
    }
}

/// One golden file: the state it starts from and the requests to send in order, each with the response the API must give.
struct GoldenFile: Codable {
    var seed: [String]
    var cases: [Case]

    struct Case: Codable {
        var name: String
        var request: RemoteJSON
        /// Names for values to keep from this response, by path (`result.id`), for later requests to send as `"$name"`.
        var capture: [String: String]?
        var response: RemoteJSON
    }
}

enum GoldenJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    /// The first difference between a golden value and what the API sent, as `path: what differs`, or nil when they match.
    /// Keys are compared by name, so a renamed field is reported as a missing key and an extra key. A golden string that ends in `*`
    /// matches any string with the rest of it as its prefix, for values that differ on every run, such as a new record's random id
    /// (`task_*`). `UPDATE_GOLDENS=1` writes the real value, so put the `*` back afterwards.
    static func difference(golden: RemoteJSON, actual: RemoteJSON, path: String = "response") -> String? {
        switch (golden, actual) {
        case (.object(let want), .object(let got)):
            for key in want.keys.sorted() where got[key] == nil {
                let extra = got.keys.filter { want[$0] == nil }.sorted()
                let hint = extra.isEmpty ? "" : " (the API sent " + extra.map { "\"\($0)\"" }.joined(separator: ", ") + " instead)"
                return "\(path).\(key): the golden file has this field and the API does not\(hint)"
            }
            for key in got.keys.sorted() where want[key] == nil {
                return "\(path).\(key): the API sends this field and the golden file does not"
            }
            for key in want.keys.sorted() {
                if let found = difference(golden: want[key]!, actual: got[key]!, path: path + "." + key) { return found }
            }
            return nil
        case (.array(let want), .array(let got)):
            if want.count != got.count { return "\(path): the golden file has \(want.count) items and the API sent \(got.count)" }
            for (index, pair) in zip(want, got).enumerated() {
                if let found = difference(golden: pair.0, actual: pair.1, path: "\(path)[\(index)]") { return found }
            }
            return nil
        case (.string(let want), .string(let got)) where want.hasSuffix("*") && got.hasPrefix(want.dropLast()):
            return nil
        default:
            return golden == actual ? nil : "\(path): the golden file has \(render(golden)) and the API sent \(render(actual))"
        }
    }

    private static func render(_ value: RemoteJSON) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return "?" }
        return text
    }
}
