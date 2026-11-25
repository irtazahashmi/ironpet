#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Why a background agent gave no answer.
package struct ReflectionError: Error, Equatable {
    package let message: String
    package init(_ message: String) { self.message = message }
}

/// The agent that reads one batch of text, and its model (nil: the agent's default).
package struct ReflectionReader: Equatable {
    package init(agent: String, model: String?) {
        self.agent = agent
        self.model = model
    }

    package let agent: String
    package let model: String?
}

/// How the memory digest and the task scan read what is new: a chat's messages after a cursor, the screen captures after the last
/// one read, and the answer of a tool-less agent. Both passes read the same sources the same way, so the code lives here once.
package enum ReflectionReading {
    package typealias Message = (id: String, user: Bool, text: String)

    /// The user's and Ghost's messages after the cursor. Tool output, screenshots and errors are left out, and so are automation
    /// turns: their prompt and the reply to it. An automation's answer is read on its own, as outside text.
    package static func unread(in thread: ChatThread, after cursor: (item: String, at: Date)?) -> [Message] {
        var start = 0
        if let cursor {
            if let at = thread.items.firstIndex(where: { $0.id.uuidString == cursor.item }) {
                start = at + 1
            } else {
                start = thread.items.firstIndex { ($0.date ?? .distantPast) > cursor.at } ?? thread.items.count
            }
        }
        var automationTurn = false
        var result: [Message] = []
        for (offset, item) in thread.items.enumerated() {
            switch item.kind {
            case .user(let text):
                automationTurn = item.origin == ChatSession.automationOrigin
                if offset >= start, !automationTurn { result.append((item.id.uuidString, true, text)) }
            case .assistant(let text):
                if offset >= start, !automationTurn { result.append((item.id.uuidString, false, text)) }
            default:
                break
            }
        }
        return result.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The newest messages that fit in `maxInput` characters, oldest first. `tag` puts a label in front of a line, from the message's
    /// position in `messages`, so an answer can point at one message.
    package static func transcript(_ messages: [Message], petName: String, maxInput: Int, tag: ((Int) -> String)? = nil) -> String {
        var lines: [String] = [], used = 0
        for (position, message) in messages.enumerated().reversed() {
            let line = (tag.map { $0(position) + " " } ?? "") + (message.user ? "User: " : "\(petName): ") + message.text
            if used + line.count > maxInput {
                if lines.isEmpty { lines.append(String(line.suffix(maxInput))) }
                break
            }
            lines.append(line)
            used += line.count + 1
        }
        return lines.reversed().joined(separator: "\n\n")
    }

    /// The captures newer than the last one read. `captures` is newest first, as `CaptureStore.recent` returns it.
    package static func freshCaptures(_ captures: [StoredCapture], after last: String?) -> [StoredCapture] {
        let last = Int64(last ?? "") ?? 0
        return captures.filter { $0.id > last }
    }

    /// The newest captures that fit in `maxInput` characters, oldest first. `fresh` is newest first.
    package static func screenText(_ fresh: [StoredCapture], maxInput: Int) -> String {
        var lines: [String] = [], used = 0
        for capture in fresh {
            let line = "\(capture.appName) · \(capture.window): \(capture.text)"
            if used + line.count > maxInput {
                if lines.isEmpty { lines.append(String(line.suffix(maxInput))) }
                break
            }
            lines.append(line)
            used += line.count + 1
        }
        return lines.reversed().joined(separator: "\n\n")
    }

    /// A short digest of a text, kept as a cursor so a changed text is read again and an unchanged one is not.
    package static func stamp(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The first JSON object in an answer, also when the agent wrapped it in a code fence or a sentence.
    package static func jsonObject(in answer: String) -> [String: Any]? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8))) as? [String: Any]
    }
}

/// Runs one prompt on an agent that may only answer: no MCP servers, a scratch folder, every permission request refused.
package enum ReflectionAgent {
    /// `scratch` is the folder under `~/.ironpet/scratch`, `feature` the Usage row the turn counts under, `refusal` the reason shown
    /// to the agent when it asks for a permission, and `settings` where the user picks the agent (for the error text).
    @MainActor
    package static func run(prompt: String, reader: ReflectionReader, spawner: ProcessSpawner, scratch: String, feature: UsageFeature,
                            refusal: String, settings: String, timeout: TimeInterval) async -> Result<String, ReflectionError> {
        guard let agent = AgentCatalog.agent(id: reader.agent) else {
            return .failure(ReflectionError("the agent \"\(reader.agent)\" is not available. Pick another in Settings → \(settings)."))
        }
        let workspace = Paths.root.appendingPathComponent("scratch/\(scratch)")
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let backend = ACPBackend(agent: agent, spawner: spawner)
        backend.restricted = true
        backend.usageFeature = feature
        backend.onPermission = { _, respond in respond(.deny(refusal)) }
        let turn = ACPTurn(prompt: prompt, preamble: nil, workspace: workspace, resume: nil, model: reader.model, images: [], files: [])
        let result = Answer()
        let task = Task { @MainActor in
            await backend.runTurn(turn) { event in
                switch event {
                case .assistant(let chunk): result.answer += chunk
                case .finished(let error): result.finish(error.map { .failure(ReflectionError($0)) } ?? .success(result.answer))
                case .needsSignIn: result.finish(.failure(ReflectionError("\(agent.name) needs you to sign in. Open it in the chat once.")))
                case .needsRuntime: result.finish(.failure(ReflectionError("\(agent.name) needs Node 22 or Bun. Open it in the chat once.")))
                default: break
                }
            }
        }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            result.finish(.failure(ReflectionError("the agent did not answer within \(Int(timeout)) seconds")))
        }
        let value = await result.wait()
        watchdog.cancel()
        task.cancel()
        backend.cancel()
        backend.shutdown()
        return value
    }

    /// One answer, delivered once, whichever of the turn and the watchdog ends first.
    @MainActor
    private final class Answer {
        var answer = ""
        private var value: Result<String, ReflectionError>?
        private var continuation: CheckedContinuation<Result<String, ReflectionError>, Never>?

        func finish(_ result: Result<String, ReflectionError>) {
            guard value == nil else { return }
            value = result
            continuation?.resume(returning: result)
            continuation = nil
        }

        func wait() async -> Result<String, ReflectionError> {
            if let value { return value }
            return await withCheckedContinuation { continuation = $0 }
        }
    }
}
