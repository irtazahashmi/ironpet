import XCTest

/// The core builds on platforms that have no AppKit, SwiftUI or other Mac framework, so a file under `Sources/IronPetCore` may
/// import only the modules listed here. Everything the Mac needs goes behind a protocol in `Platform/` with an adapter in
/// `Sources/IronPet/Platform/Mac/`. The scan reads the source files, like `BoundaryTests` does for the API layer.
final class ImportAllowListTests: XCTestCase {
    /// Modules every platform has, or that the package provides to the core.
    static let alwaysAllowed: Set<String> = ["Foundation", "Dispatch", "IronPetKit", "JMESPath", "QuickJS"]

    /// Modules that exist on some platforms only. An import needs an enclosing `#if` chain that tests `canImport` of one of the
    /// names listed for it, so the other platforms take the fallback branch.
    static let guarded: [String: [String]] = [
        "Combine": ["Combine"],
        "CryptoKit": ["CryptoKit"],
        "Crypto": ["CryptoKit"],
        "SQLite3": ["SQLite3"],
        "CSQLite": ["SQLite3"],
        "Darwin": ["Darwin"],
        "Glibc": ["Glibc"],
        "FoundationNetworking": ["FoundationNetworking"],
        "NaturalLanguage": ["NaturalLanguage"],
    ]

    struct Violation: Equatable, CustomStringConvertible {
        var file: String
        var line: Int
        var module: String
        var reason: String
        var description: String { "\(file):\(line): import \(module) \(reason)" }
    }

    private static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/IronPetCore")
    }

    private static func swiftFiles() -> [(path: String, text: String)] {
        let root = sources
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (String(url.path.dropFirst(root.path.count + 1)), text)
        }
    }

    /// Every import in `text` that is not allowed. Lines inside a multi-line string are skipped, since they are not Swift.
    static func violations(in text: String, file: String) -> [Violation] {
        var found: [Violation] = []
        var conditions: [String] = []
        var inString = false
        for (offset, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let wasInString = inString
            if line.components(separatedBy: "\"\"\"").count % 2 == 0 { inString.toggle() }
            if wasInString { continue }
            if line.hasPrefix("#if ") {
                conditions.append(line)
            } else if line.hasPrefix("#elseif ") || line == "#else" {
                if !conditions.isEmpty { conditions[conditions.count - 1] += " " + line }
            } else if line == "#endif" {
                if !conditions.isEmpty { conditions.removeLast() }
            }
            guard let range = line.range(of: #"^(@testable\s+|@_exported\s+)*import\s+(?:(?:struct|class|enum|protocol|typealias|func|var|let)\s+)?[A-Za-z_][A-Za-z0-9_]*"#,
                                         options: .regularExpression) else { continue }
            let module = line[range].split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init) ?? ""
            let name = module.split(separator: ".").first.map(String.init) ?? module
            if alwaysAllowed.contains(name) { continue }
            if let guards = guarded[name] {
                let chain = conditions.joined(separator: " ")
                if guards.contains(where: { chain.contains("canImport(\($0))") }) { continue }
                found.append(Violation(file: file, line: offset + 1, module: name, reason: "needs an enclosing #if canImport(\(guards.joined(separator: ") or canImport(")))"))
            } else {
                found.append(Violation(file: file, line: offset + 1, module: name, reason: "is not in the core's allow list. Put the call behind a protocol in Platform/ with an adapter in Sources/IronPet/Platform/Mac/"))
            }
        }
        return found
    }

    func testCoreFilesImportOnlyAllowedModules() {
        let files = Self.swiftFiles()
        XCTAssertGreaterThan(files.count, 100, "Sources/IronPetCore was not found or is empty")
        let violations = files.flatMap { Self.violations(in: $0.text, file: $0.path) }
        XCTAssertTrue(violations.isEmpty, "the core imports a module outside its allow list:\n" + violations.map(\.description).joined(separator: "\n"))
    }

    func testTheScanNamesAFileThatImportsAMacFramework() {
        for module in ["AppKit", "SwiftUI", "os", "Security", "ScreenCaptureKit", "Vision", "AVFoundation", "Carbon", "UserNotifications", "Network"] {
            let found = Self.violations(in: "import Foundation\nimport \(module)\n", file: "Chat/Example.swift")
            XCTAssertEqual(found.map(\.module), [module], module)
            XCTAssertEqual(found.first?.file, "Chat/Example.swift")
            XCTAssertEqual(found.first?.line, 2)
        }
    }

    func testCombineIsAllowedOnlyUnderCanImport() {
        XCTAssertEqual(Self.violations(in: "import Combine\n", file: "A.swift").map(\.module), ["Combine"])
        XCTAssertEqual(Self.violations(in: "#if canImport(Combine)\nimport Combine\n#endif\nimport Combine\n", file: "A.swift").map(\.line), [4])
        XCTAssertTrue(Self.violations(in: "#if canImport(CryptoKit)\nimport CryptoKit\n#else\nimport Crypto\n#endif\n", file: "A.swift").isEmpty)
        XCTAssertEqual(Self.violations(in: "#if os(macOS)\nimport Combine\n#endif\n", file: "A.swift").map(\.module), ["Combine"])
    }

    func testImportsInsideAMultiLineStringAreNotCode() {
        let text = "let js = \"\"\"\nimport AppKit\nimport { x } from \"y\"\n\"\"\"\nimport Foundation\n"
        XCTAssertTrue(Self.violations(in: text, file: "A.swift").isEmpty)
    }
}
