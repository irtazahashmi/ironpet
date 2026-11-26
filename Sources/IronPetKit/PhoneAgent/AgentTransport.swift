import Foundation

/// One request to a provider, without `URLRequest` so the loop needs nothing but Foundation.
public struct AgentHTTPRequest: Equatable, Sendable {
    public var url: URL
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, headers: [String: String], body: Data) {
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// Sends a request and yields the lines of the answer as they arrive. The app implements it with `URLSession`, and tests with fixtures. A
/// status other than 2xx throws an `AgentError` that carries the provider's own message.
public protocol AgentTransport: Sendable {
    func lines(for request: AgentHTTPRequest) -> AsyncThrowingStream<String, Error>
}

/// A provider's wire format: how to ask, and how to read the stream back.
public protocol AgentProviderAdapter: Sendable {
    func request(system: String, turns: [AgentTurn], tools: [any AgentTool], config: AgentConfig, apiKey: String) throws -> AgentHTTPRequest
    /// A reader for the stream of one request. It keeps what it needs between events, such as the pieces of a call's arguments.
    func makeReader() -> any AgentStreamReading
}

/// Reads the server-sent events of one response. A piece of text, or a call that is complete, comes back as events.
public protocol AgentStreamReading: AnyObject {
    func read(_ event: SSEEvent) throws -> [AgentStreamEvent]
}

/// Turns a provider's lines into `AgentStreamEvent`s.
enum AgentStreamReader {
    static func events(lines: AsyncThrowingStream<String, Error>, adapter: any AgentProviderAdapter) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                let reader = adapter.makeReader()
                do {
                    for try await line in lines {
                        if let event = parser.feed(line) {
                            for out in try reader.read(event) { continuation.yield(out) }
                        }
                    }
                    if let event = parser.finish() {
                        for out in try reader.read(event) { continuation.yield(out) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
