import Foundation
import JMESPath

/// The parts of agent-trigger's poll engine that ironpet needs: run a command with a timeout and an output cap,
/// pull items out of the output, remember which ones were seen, and filter them. Nothing here talks to
/// agent-trigger or reads its files.

package struct CommandResult: Equatable {
    package init(
        code: Int32? = nil,
        stdout: String = "",
        stderr: String = "",
        truncated: Bool = false,
        timedOut: Bool = false,
        spawnError: String? = nil
    ) {
        self.code = code
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
        self.timedOut = timedOut
        self.spawnError = spawnError
    }

    package var code: Int32?
    package var stdout = ""
    package var stderr = ""
    package var truncated = false
    package var timedOut = false
    package var spawnError: String?

    package var ok: Bool { spawnError == nil && !timedOut && code == 0 }

    /// Short text for history and bubbles.
    package var summary: String {
        if let spawnError { return spawnError }
        if timedOut { return "timed out" }
        let out = (stdout.isEmpty ? stderr : stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        let head = code == 0 ? "" : "exit \(code ?? -1)" + (out.isEmpty ? "" : ": ")
        return head + String(out.prefix(300))
    }
}

package enum CommandRunner {
    package static let maxOutput = 256 * 1024

    /// Runs `/bin/sh -c command`, killing it when it runs past `timeout` or prints more than `maxOutput` bytes.
    package static func run(shell command: String, spawner: ProcessSpawner, timeout: TimeInterval, environment: [String: String]? = nil,
                    stdin: Data? = nil, maxBytes: Int = maxOutput) async -> CommandResult {
        await run(executable: "/bin/sh", arguments: ["-c", command], spawner: spawner, timeout: timeout, environment: environment,
                  stdin: stdin, maxBytes: maxBytes)
    }

    package static func run(executable: String, arguments: [String], spawner: ProcessSpawner, timeout: TimeInterval,
                    environment: [String: String]? = nil, stdin: Data? = nil, maxBytes: Int = maxOutput) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: runBlocking(executable: executable, arguments: arguments, spawner: spawner, timeout: timeout,
                                                           environment: environment, stdin: stdin, maxBytes: maxBytes))
            }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    package static func runBlocking(executable: String, arguments: [String], spawner: ProcessSpawner, timeout: TimeInterval,
                            environment: [String: String]?, stdin: Data?, maxBytes: Int) -> CommandResult {
        var result = CommandResult()
        let process: RunningProcess
        do {
            process = try spawner.spawn(ProcessSpec(executable: executable, arguments: arguments, environment: environment,
                                                    input: stdin == nil ? .null : .pipe))
        } catch {
            result.spawnError = error.localizedDescription
            return result
        }
        let timedOut = Flag(), overflow = Flag()
        let killer = DispatchWorkItem { if process.isRunning { timedOut.set(); process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        if let stdin, let input = process.input {
            DispatchQueue.global().async {
                try? input.write(contentsOf: stdin)
                try? input.close()
            }
        }
        func drain(_ pipe: FileHandle?) -> Data {
            guard let pipe else { return Data() }
            var data = Data()
            while true {
                let chunk = pipe.availableData
                if chunk.isEmpty { break }
                if data.count + chunk.count > maxBytes {
                    data.append(chunk.prefix(maxBytes - data.count))
                    overflow.set()
                    if process.isRunning { process.terminate() }
                    break
                }
                data.append(chunk)
            }
            return data
        }
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errBox.set(drain(process.error)); group.leave() }
        let outData = drain(process.output)
        group.wait()
        process.waitUntilExit()
        killer.cancel()
        result.stdout = String(decoding: outData, as: UTF8.self)
        result.stderr = String(decoding: errBox.get(), as: UTF8.self)
        result.truncated = overflow.isSet
        result.timedOut = timedOut.isSet
        result.code = process.terminationStatus
        return result
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.withLock { data = d } }
        func get() -> Data { lock.withLock { data } }
    }

    /// `PATH` as the user's login shell has it, so `gh`, `jq` and friends are found.
    package static func defaultEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = LoginShell.path
        return env
    }
}

// MARK: - JMESPath

/// Item extraction uses JMESPath (the pure-Swift jmespath.swift package), run inside the app. No jq, no extra process.
/// Filters replace agent-trigger's `where`: `[?conclusion=='failure']`, `[?contains(['open', 'new'], state)]`,
/// `[?starts_with(title, 'fix')]`. JMESPath has no regular expressions, so those cannot be expressed.
package enum JMES {
    package struct Failure: Error, LocalizedError {
        package init(message: String) {
            self.message = message
        }

        package let message: String
        package var errorDescription: String? { message }
    }

    /// Whether `expression` parses, with the parser's message when it does not.
    package static func check(_ expression: String) -> String? {
        do { _ = try JMESExpression.compile(expression); return nil } catch { return "\(error)" }
    }

    /// Runs `expression` over JSON text. Nil for a JSON null or no match. The library reads the text itself, because
    /// values from `JSONSerialization` (`NSNumber`) do not compare as numbers in a filter.
    package static func search(_ expression: String, json: String) throws -> Any? {
        do {
            let result = try JMESExpression.compile(expression).search(json: json)
            return result is NSNull ? nil : result
        } catch {
            throw Failure(message: "JMESPath `\(expression)`: \(error)")
        }
    }

    /// Runs `expression` over a value the library produced earlier (an item from `search(_:json:)`).
    package static func search(_ expression: String, in object: Any) throws -> Any? {
        do {
            let result = try JMESExpression.compile(expression).search(object: object)
            return result is NSNull ? nil : result
        } catch {
            throw Failure(message: "JMESPath `\(expression)`: \(error)")
        }
    }
}

// MARK: - Items

package struct PollItem {
    package init(id: String, version: String, value: [String: Any]) {
        self.id = id
        self.version = version
        self.value = value
    }

    package var id: String
    package var version: String
    package var value: [String: Any]
}

package enum PollExtractor {
    package struct Failure: Error, LocalizedError {
        package init(message: String) {
            self.message = message
        }

        package let message: String
        package var errorDescription: String? { message }
    }

    /// Items in the output for a poll trigger.
    package static func items(from result: CommandResult, trigger t: Automation.Trigger) throws -> [PollItem] {
        switch t.mode ?? "json" {
        case "lines":
            return result.stdout.split(whereSeparator: \.isNewline).map { line in
                let text = String(line).trimmingCharacters(in: .whitespaces)
                return PollItem(id: text, version: "", value: ["line": text, "title": text, "id": text])
            }.filter { !$0.id.isEmpty }
        case "text":
            let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [PollItem(id: "text", version: text, value: ["text": text, "title": String(text.prefix(120))])]
        case "exit_code":
            let code = Int(result.code ?? -1)
            return [PollItem(id: "exit_code", version: String(code), value: ["exit_code": code, "title": "exit \(code)", "output": String(result.stdout.prefix(500))])]
        default:
            return try jsonItems(result.stdout, trigger: t)
        }
    }

    private static func jsonItems(_ text: String, trigger t: Automation.Trigger) throws -> [PollItem] {
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil else {
            throw Failure(message: "the output is not JSON")
        }
        // An array result is the list of items. Any other result is one item.
        let found = try JMES.search(t.items ?? "@", json: text)
        let values: [Any] = (found as? [Any]) ?? found.map { [$0] } ?? []
        return try values.map { value in
            let dict: [String: Any] = (value as? [String: Any]) ?? ["value": value, "title": "\(value)"]
            let id = try expression(t.id, on: dict) ?? defaultID(dict)
            let version = try expression(t.version, on: dict) ?? ""
            return PollItem(id: id, version: version, value: dict)
        }
    }

    private static func expression(_ expr: String?, on item: [String: Any]) throws -> String? {
        guard let expr, !expr.isEmpty, let value = try JMES.search(expr, in: item) else { return nil }
        return stringify(value)
    }

    /// Strings as they are, numbers and booleans plainly, everything else as sorted JSON.
    private static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            if n.isJSONBoolean { return n.boolValue ? "true" : "false" }
            return n.doubleValue == n.doubleValue.rounded() ? String(n.int64Value) : String(n.doubleValue)
        }
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
    }

    private static func defaultID(_ dict: [String: Any]) -> String {
        for key in ["id", "url", "number", "key", "name", "title"] {
            if let value = dict[key], !(value is NSNull) { return stringify(value) }
        }
        return stringify(dict)
    }
}
