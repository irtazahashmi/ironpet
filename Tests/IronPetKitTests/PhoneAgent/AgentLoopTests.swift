import XCTest
@testable import IronPetKit

/// A transport that answers each request with the next stream, and keeps the requests.
final class ScriptedTransport: AgentTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String]
    private(set) var requests: [AgentHTTPRequest] = []

    init(_ answers: [String]) { self.answers = answers }

    func lines(for request: AgentHTTPRequest) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        requests.append(request)
        let text = answers.isEmpty ? "" : answers.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for line in text.components(separatedBy: "\n") { continuation.yield(line) }
            continuation.finish()
        }
    }

    func body(_ index: Int) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: requests[index].body) as? [String: Any])
    }
}

struct FixedKey: AgentKeyProviding {
    var key: String?
    func apiKey(for provider: AgentProvider) -> String? { key }
}

/// An inbox remote that can be switched out of reach, and records what it was given.
final class FakeMac: InboxRemote, @unchecked Sendable {
    private let lock = NSLock()
    private var reachable = false
    private(set) var delivered: [QueuedInboxItem] = []
    private(set) var attempts = 0
    var refuse: String?

    func setReachable(_ value: Bool) { lock.lock(); reachable = value; lock.unlock() }

    func items() async throws -> [InboxEntry] {
        guard reachable else { throw InboxDeliveryError.unreachable }
        return delivered.map { InboxEntry(id: $0.id, title: $0.title) }
    }

    func deliver(_ item: QueuedInboxItem) async throws {
        lock.lock(); defer { lock.unlock() }
        attempts += 1
        guard reachable else { throw InboxDeliveryError.unreachable }
        if let refuse { throw InboxDeliveryError.rejected(refuse) }
        // The Mac ignores an id it has seen.
        if !delivered.contains(where: { $0.id == item.id }) { delivered.append(item) }
    }

    func markDone(id: String) async throws { guard reachable else { throw InboxDeliveryError.unreachable } }
    func remove(id: String, note: String?) async throws { guard reachable else { throw InboxDeliveryError.unreachable } }
}

final class AgentLoopTests: XCTestCase {
    private func loop(_ transport: ScriptedTransport, tools: [any AgentTool], key: String? = "sk-test") -> AgentLoop {
        AgentLoop(transport: transport, keys: FixedKey(key: key), tools: tools, system: PhoneAgentPrompt.system(skills: PhoneAgentSkills.bundled))
    }

    // MARK: S4, Anthropic

    func testAnAnthropicToolCallRunsAndItsResultGoesBackUntilTheFinalAnswer() async throws {
        let echo = RecordingTool(name: "inbox_add", reply: "Added.")
        let transport = ScriptedTransport([
            AgentFixtures.anthropicToolCall(arguments: ["{\"title\": \"Call", " Tom\", \"due\"", ": \"2026-11-27\"}"]),
            AgentFixtures.anthropicText,
        ])
        var streamed = ""
        let turns = try await loop(transport, tools: [echo]).run("remind me to call Tom tomorrow", history: [], config: AgentConfig(provider: .anthropic)) {
            if case .text(let piece) = $0 { streamed += piece }
        }
        XCTAssertEqual(echo.calls.count, 1)
        XCTAssertEqual(echo.calls.first?["title"] as? String, "Call Tom", "the pieces of the arguments were joined")
        XCTAssertEqual(echo.calls.first?["due"] as? String, "2026-11-27")
        XCTAssertEqual(transport.requests.count, 2, "one request for the call and one with its result")
        let second = try transport.body(1)
        let messages = try XCTUnwrap(second["messages"] as? [[String: Any]])
        let last = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(last.first?["type"] as? String, "tool_result")
        XCTAssertEqual(last.first?["tool_use_id"] as? String, "toolu_01")
        XCTAssertEqual(last.first?["content"] as? String, "Added.")
        let assistant = try XCTUnwrap(messages[messages.count - 2]["content"] as? [[String: Any]])
        XCTAssertEqual(assistant.last?["type"] as? String, "tool_use", "the call is in the history the model sees")
        XCTAssertEqual(streamed, "Adding that.That needs the Mac. Ask the agent there.")
        guard case .assistant(let final, let calls) = try XCTUnwrap(turns.last) else { return XCTFail("the loop ended on an answer") }
        XCTAssertEqual(final, "That needs the Mac. Ask the agent there.")
        XCTAssertTrue(calls.isEmpty)
    }

    func testTheAnthropicRequestCarriesTheKeyModelToolsAndStreaming() throws {
        let tool = RecordingTool(name: "inbox_add", reply: "")
        let request = try AnthropicAdapter().request(system: "S", turns: [.user("hi")], tools: [tool], config: AgentConfig(provider: .anthropic), apiKey: "sk-ant")
        XCTAssertEqual(request.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.headers["x-api-key"], "sk-ant")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, "S")
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["name"] as? String, "inbox_add")
    }

    // MARK: S4, OpenAI

    func testAnOpenAIFunctionCallRunsAndItsResultGoesBackUntilTheFinalAnswer() async throws {
        let echo = RecordingTool(name: "inbox_add", reply: "Added.")
        let transport = ScriptedTransport([
            AgentFixtures.openAIToolCall(arguments: "{\"title\":\"Call Tom\"}"),
            AgentFixtures.openAIText,
        ])
        var streamed = ""
        let turns = try await loop(transport, tools: [echo]).run("remind me to call Tom", history: [], config: AgentConfig(provider: .openai)) {
            if case .text(let piece) = $0 { streamed += piece }
        }
        XCTAssertEqual(echo.calls.first?["title"] as? String, "Call Tom")
        XCTAssertEqual(transport.requests.count, 2)
        let second = try transport.body(1)
        let input = try XCTUnwrap(second["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String ?? $0["role"] as? String }, ["user", "function_call", "function_call_output"])
        XCTAssertEqual(input.last?["call_id"] as? String, "call_01")
        XCTAssertEqual(input.last?["output"] as? String, "Added.")
        XCTAssertEqual(second["store"] as? Bool, false)
        XCTAssertEqual(streamed, "Done: call Tom is in your inbox.")
        guard case .assistant(let final, _) = try XCTUnwrap(turns.last) else { return XCTFail() }
        XCTAssertEqual(final, "Done: call Tom is in your inbox.")
    }

    func testTheOpenAIRequestCarriesTheKeyModelAndTools() throws {
        let request = try OpenAIAdapter().request(system: "S", turns: [.user("hi")], tools: [RecordingTool(name: "x", reply: "")],
                                                  config: AgentConfig(provider: .openai, model: "gpt-test"), apiKey: "sk-oai")
        XCTAssertEqual(request.url.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.headers["authorization"], "Bearer sk-oai")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-test")
        XCTAssertEqual(body["instructions"] as? String, "S")
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["type"] as? String, "function")
    }

    // MARK: Loop rules

    func testAToolErrorGoesBackToTheModelAsTheResult() async throws {
        let failing = RecordingTool(name: "inbox_add", reply: "", error: AgentError("title is required"))
        let transport = ScriptedTransport([AgentFixtures.anthropicToolCall(arguments: ["{}"]), AgentFixtures.anthropicText])
        _ = try await loop(transport, tools: [failing]).run("x", history: [], config: AgentConfig())
        let messages = try XCTUnwrap(transport.body(1)["messages"] as? [[String: Any]])
        let result = try XCTUnwrap((messages.last?["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(result["is_error"] as? Bool, true)
        XCTAssertEqual(result["content"] as? String, "title is required")
    }

    func testAnUnknownToolIsAnErrorResultAndTheLoopGoesOn() async throws {
        let transport = ScriptedTransport([AgentFixtures.anthropicToolCall(name: "launch_missiles", arguments: ["{}"]), AgentFixtures.anthropicText])
        let turns = try await loop(transport, tools: []).run("x", history: [], config: AgentConfig())
        XCTAssertEqual(transport.requests.count, 2)
        guard case .toolResults(let results) = turns[2] else { return XCTFail() }
        XCTAssertTrue(results[0].isError)
    }

    func testTheLoopStopsAfterTheMostRoundsWhenTheModelKeepsCallingTools() async throws {
        let tool = RecordingTool(name: "inbox_add", reply: "ok")
        let transport = ScriptedTransport(Array(repeating: AgentFixtures.anthropicToolCall(arguments: ["{}"]), count: 20))
        let turns = try await loop(transport, tools: [tool]).run("x", history: [], config: AgentConfig())
        XCTAssertEqual(transport.requests.count, AgentLoop.maxRounds)
        guard case .assistant(let text, let calls) = try XCTUnwrap(turns.last) else { return XCTFail() }
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(text.contains("stopped"))
    }

    func testWithoutAKeyNothingIsSent() async throws {
        let transport = ScriptedTransport([AgentFixtures.anthropicText])
        do {
            _ = try await loop(transport, tools: [], key: nil).run("x", history: [], config: AgentConfig())
            XCTFail("a missing key throws")
        } catch let error as AgentError {
            XCTAssertTrue(error.message.contains("API key"))
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAProviderErrorInTheStreamThrowsItsMessage() async throws {
        let transport = ScriptedTransport(["event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n"])
        do {
            _ = try await loop(transport, tools: []).run("x", history: [], config: AgentConfig())
            XCTFail()
        } catch let error as AgentError {
            XCTAssertEqual(error.message, "Overloaded")
        }
    }

    func testTheSSEParserJoinsDataLinesSkipsCommentsAndKeepsALastEventWithoutABlankLine() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed(": keep-alive"))
        XCTAssertNil(parser.feed("event: a"))
        XCTAssertNil(parser.feed("data: one"))
        XCTAssertNil(parser.feed("data:two"))
        XCTAssertEqual(parser.feed(""), SSEEvent(name: "a", data: "one\ntwo"))
        XCTAssertNil(parser.feed("data: last"))
        XCTAssertEqual(parser.finish(), SSEEvent(name: nil, data: "last"))
    }

    func testConfigFallsBackToTheProvidersDefaultModel() {
        XCTAssertEqual(AgentConfig().provider, .anthropic)
        XCTAssertEqual(AgentConfig().model, "claude-sonnet-5-5")
        XCTAssertEqual(AgentConfig(provider: .openai, model: "  ").model, AgentProvider.openai.defaultModel)
    }
}

final class RecordingTool: AgentTool, @unchecked Sendable {
    let name: String
    private let reply: String
    private let error: Error?
    private let lock = NSLock()
    private var recorded: [[String: Any]] = []

    init(name: String, reply: String, error: Error? = nil) { self.name = name; self.reply = reply; self.error = error }

    var calls: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return recorded }
    var detail: String { "test" }
    var schema: [String: AgentJSON] { Self.objectSchema(["title": Self.property("string", "t")]) }

    func run(_ arguments: [String: Any]) async throws -> String {
        lock.lock(); recorded.append(arguments); lock.unlock()
        if let error { throw error }
        return reply
    }
}
