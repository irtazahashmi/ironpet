import Foundation
import IronPetKit

/// One JSON-RPC method: its name, the REST route that serves the same call over HTTP, and the code that runs it.
/// `docs/protocol.md` lists every method here, and `ContractDocTests` fails when one is missing.
@MainActor
package struct RPCMethod {
    package let name: String
    /// The `/v1` route and verb that serve the same call, such as `GET /v1/tasks`, or `none` when REST has no route for it.
    package let route: String
    /// The Swift type of `params` and of `result`, as `docs/protocol.md` names them.
    package let params: String
    package let result: String
    package let run: (RemoteJSON?) async throws -> RemoteJSON

    package init(name: String, route: String, params: String, result: String, run: @escaping (RemoteJSON?) async throws -> RemoteJSON) {
        self.name = name
        self.route = route
        self.params = params
        self.result = result
        self.run = run
    }
}

/// Runs JSON-RPC requests against an `IronPetAPI`. It is a method table and an envelope, not a transport: a stdio host,
/// the HTTP routes or a WebSocket hand it a decoded `JSONRPCRequest` and send back what it returns.
@MainActor
package final class RPCDispatcher {
    package private(set) var methods: [String: RPCMethod] = [:]
    private let api: IronPetAPI

    /// `JSONRPCError.code` for each `APIError.Code`. They sit in the range JSON-RPC 2.0 leaves to the server.
    package nonisolated static func code(for code: APIError.Code) -> Int {
        switch code {
        case .notFound: return -32001
        case .invalid: return -32002
        case .conflict: return -32003
        case .unavailable: return -32004
        case .failed: return -32005
        case .unsupported: return -32006
        }
    }

    package init(api: IronPetAPI) {
        self.api = api
        registerInbox()
        registerAlerts()
        registerAgents()
        registerAgentRecords()
        registerAutomations()
        registerChat()
        registerMemory()
        registerSettings()
        registerToday()
        registerBubbles()
        registerNotifications()
        registerMeetings()
        registerSession()
        registerNode()
        registerScreen()
    }

    /// The connection the request in flight arrived on, for the methods that depend on it. Set by `handle(_:connection:)`.
    @TaskLocal private static var currentConnection: RPCConnection?

    /// Adds a method. Tests use it to reach an error that no real method raises with in-memory stores, such as `failed`.
    package func register(_ method: RPCMethod) { methods[method.name] = method }

    /// The methods in name order, for the documentation check.
    package var all: [RPCMethod] { methods.values.sorted { $0.name < $1.name } }

    // MARK: Requests

    /// Runs one request and returns the response to send. A call that throws becomes an `error` response, never a crash.
    ///
    /// `connection` is what the transport knows about the caller. `allowed`, when given, limits the connection to those methods:
    /// the remote event socket serves `session.hello` only, so a device cannot reach the rest of the table through it.
    package func handle(_ request: JSONRPCRequest, connection: RPCConnection? = nil, allowed: Set<String>? = nil) async -> JSONRPCResponse {
        guard request.jsonrpc == JSONRPC.version else {
            return JSONRPCResponse(id: request.id, error: JSONRPCError(code: JSONRPCError.invalidRequest, message: "jsonrpc must be \"2.0\""))
        }
        guard let method = methods[request.method], allowed?.contains(request.method) ?? true else {
            return JSONRPCResponse(id: request.id, error: JSONRPCError(
                code: JSONRPCError.methodNotFound, message: "no method \"\(request.method)\"", data: .object(["method": .string(request.method)])))
        }
        do {
            let result = try await Self.$currentConnection.withValue(connection) { try await method.run(request.params) }
            return JSONRPCResponse(id: request.id, result: result)
        } catch let error as JSONRPCError {
            return JSONRPCResponse(id: request.id, error: error)
        } catch let error as CapabilityError {
            // The wire form of "nothing can do this": the same fields the Swift error carries, so a client can say which and where.
            switch error {
            case .unsupported(let capability, let platform):
                return JSONRPCResponse(id: request.id, error: JSONRPCError(
                    code: Self.code(for: .unsupported), message: error.localizedDescription,
                    data: .object(["code": .string(APIError.Code.unsupported.rawValue), "capability": .string(capability), "platform": .string(platform)])))
            }
        } catch {
            let api = APIError.wrap(error)
            return JSONRPCResponse(id: request.id, error: JSONRPCError(
                code: Self.code(for: api.code), message: api.message, data: .object(["code": .string(api.code.rawValue)])))
        }
    }

    /// Runs one line of a stdio stream (newline-delimited JSON). A line that is not JSON, or not a request, gets the error the
    /// JSON-RPC 2.0 specification names, with a `null` id because no id could be read.
    package func handle(line: Data, connection: RPCConnection? = nil, allowed: Set<String>? = nil) async -> Data {
        let response: JSONRPCResponse
        if (try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])) == nil {
            response = JSONRPCResponse(id: .null, error: JSONRPCError(code: JSONRPCError.parseError, message: "the line is not JSON"))
        } else if let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: line) {
            response = await handle(request, connection: connection, allowed: allowed)
        } else {
            response = JSONRPCResponse(id: .null, error: JSONRPCError(code: JSONRPCError.invalidRequest, message: "the line is not a JSON-RPC 2.0 request"))
        }
        return Self.encode(response)
    }

    /// The notification a server sends a client for one event. The method is the event's name, and `params` holds `seq`, `at` and,
    /// when one thing changed, its `id`. The client reads the area again through the methods above.
    package nonisolated static func notification(for event: APIEvent) -> JSONRPCNotification {
        var fields: [String: RemoteJSON] = ["seq": .int(event.seq), "at": .string(isoFormatter.string(from: event.at))]
        if let id = event.id { fields["id"] = .string(id) }
        if let agent = event.agentId { fields["agentId"] = .string(agent) }
        return JSONRPCNotification(method: event.kind.rawValue, params: .object(fields))
    }

    private nonisolated static var isoFormatter: ISO8601DateFormatter { ISO8601DateFormatter() }

    /// The bytes that go on the wire: keys sorted, dates as ISO 8601, no pretty printing, so one message is one line.
    package nonisolated static func encode<T: Encodable>(_ value: T) -> Data {
        (try? wireEncoder.encode(value)) ?? Data()
    }

    // MARK: Registration

    private nonisolated static var wireEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private nonisolated static var wireDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A method with `params` and a `result`. `params` is decoded as `P`; a failure is `-32602` and names the field.
    private func add<P: Decodable, R: Encodable>(_ name: String, _ route: String, params: String, result: String,
                                                  _ call: @escaping (P) async throws -> R) {
        methods[name] = RPCMethod(name: name, route: route, params: params, result: result) { raw in
            let value: P = try Self.decode(raw, as: P.self)
            return try Self.value(try await call(value))
        }
    }

    /// A method that takes no `params`.
    private func add<R: Encodable>(_ name: String, _ route: String, result: String, _ call: @escaping () async throws -> R) {
        methods[name] = RPCMethod(name: name, route: route, params: "none", result: result) { _ in try Self.value(try await call()) }
    }

    /// A method that takes `params` and returns nothing, so `result` is `null`.
    private func addVoid<P: Decodable>(_ name: String, _ route: String, params: String, _ call: @escaping (P) async throws -> Void) {
        add(name, route, params: params, result: "null") { (value: P) -> RemoteJSON in
            try await call(value)
            return .null
        }
    }

    private func addVoid(_ name: String, _ route: String, _ call: @escaping () async throws -> Void) {
        add(name, route, result: "null") { () -> RemoteJSON in
            try await call()
            return .null
        }
    }

    private nonisolated static func decode<P: Decodable>(_ raw: RemoteJSON?, as type: P.Type) throws -> P {
        // A call with no `params` is an empty object. A request type still needs every field that is not optional, as its Codable does.
        let data = try wireEncoder.encode(raw ?? .object([:]))
        do {
            return try wireDecoder.decode(P.self, from: data)
        } catch let error as DecodingError {
            throw invalidParams(error)
        }
    }

    private nonisolated static func value<R: Encodable>(_ result: R) throws -> RemoteJSON {
        try wireDecoder.decode(RemoteJSON.self, from: try wireEncoder.encode(Wrapped(result)))
    }

    /// Lets a bare value, a string or an array be encoded at the top level on every platform.
    private struct Wrapped<R: Encodable>: Encodable {
        init(_ value: R) { self.value = value }
        let value: R
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }

    private nonisolated static func invalidParams(_ error: DecodingError) -> JSONRPCError {
        let path: [CodingKey]
        let reason: String
        switch error {
        case .keyNotFound(let key, let context): path = context.codingPath + [key]; reason = "is missing"
        case .typeMismatch(_, let context): path = context.codingPath; reason = "has the wrong type"
        case .valueNotFound(_, let context): path = context.codingPath; reason = "has no value"
        case .dataCorrupted(let context): path = context.codingPath; reason = "is not valid: " + context.debugDescription
        @unknown default: path = []; reason = "is not valid"
        }
        let field = path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        return JSONRPCError(code: JSONRPCError.invalidParams, message: "params: \(field.isEmpty ? "the value" : field) \(reason)",
                            data: .object(["field": .string(field)]))
    }

    // MARK: Parameter types

    /// `params` for a call about one thing.
    package struct ID: Codable, Equatable {
        package var id: String
    }

    package struct UUIDParam: Codable, Equatable {
        package var id: UUID
    }

    package struct SetEnabled: Codable, Equatable {
        package var id: String
        package var enabled: Bool
    }

    package struct SetMode: Codable, Equatable {
        package var id: String
        package var agentId: String?
    }

    package struct MemoryCall: Codable, Equatable {
        package var name: String
        package var arguments: RemoteJSON?
        package var caller: String?
    }

    // MARK: Areas

    private func registerInbox() {
        let inbox = api.tasks
        add("inbox.list", "GET /v1/suggestions", result: "[TaskSuggestion]") { inbox.suggestions }
        add("inbox.add", "none", params: "SuggestTaskRequest", result: "[TaskSuggestion]") { (p: SuggestTaskRequest) in inbox.suggest(p) }
        addVoid("inbox.done", "POST /v1/suggestions/:id/accept", params: "ID") { (p: ID) in try inbox.done(p.id) }
        addVoid("inbox.remove", "POST /v1/suggestions/:id/reject", params: "RemoveSuggestionRequest") { (p: RemoveSuggestionRequest) in try inbox.remove(p) }
    }

    private func registerAlerts() {
        let alerts = api.alerts
        add("alerts.list", "GET /v1/alerts", result: "[Signal]") { alerts.list() }
        add("alerts.get", "none", params: "ID", result: "Signal") { (p: ID) in try alerts.get(p.id) }
        addVoid("alerts.dismiss", "POST /v1/alerts/:id/dismiss", params: "ID") { (p: ID) in try alerts.dismiss(p.id) }
        addVoid("alerts.dismissAll", "POST /v1/alerts/dismiss-all") { alerts.dismissAll() }
        addVoid("alerts.ask", "POST /v1/alerts/:id/ask", params: "ID") { (p: ID) in try alerts.ask(p.id) }
    }

    private func registerAgents() {
        let agents = api.agents
        add("agents.list", "GET /v1/agents", params: "AgentScopeRequest", result: "[AgentSession]") { (p: AgentScopeRequest) in try agents.list(agentId: p.agentId) }
        add("agents.get", "GET /v1/agents/:id", params: "ID", result: "AgentSession") { (p: ID) in try agents.get(p.id) }
        addVoid("agents.acknowledge", "POST /v1/agents/:id/acknowledge", params: "ID") { (p: ID) in try agents.acknowledge(p.id) }
        addVoid("agents.acknowledgeAll", "none") { agents.acknowledgeAll() }
        addVoid("agents.ask", "POST /v1/agents/:id/ask", params: "ID") { (p: ID) in try agents.ask(p.id) }
    }

    /// The agents as records. `agents.*` above is the coding-agent sessions, so these are `agent.*`.
    private func registerAgentRecords() {
        let records = api.agentRecords
        add("agent.list", "GET /v1/agent-records", result: "[AgentRecord]") { () -> [AgentRecord] in
            guard let records else { throw APIError.unavailable("this host has no agent records") }
            return records.list()
        }
        add("agent.get", "GET /v1/agent-records/:id", params: "ID", result: "AgentRecord") { (p: ID) -> AgentRecord in
            guard let records else { throw APIError.unavailable("this host has no agent records") }
            return try records.get(p.id)
        }
        add("agent.create", "POST /v1/agent-records", params: "CreateAgentRequest", result: "AgentRecord") { (p: CreateAgentRequest) -> AgentRecord in
            guard let records else { throw APIError.unavailable("this host has no agent records") }
            return try records.create(p)
        }
        add("agent.update", "PATCH /v1/agent-records/:id", params: "UpdateAgentRequest", result: "AgentRecord") { (p: UpdateAgentRequest) -> AgentRecord in
            guard let records else { throw APIError.unavailable("this host has no agent records") }
            return try records.update(p)
        }
        addVoid("agent.delete", "DELETE /v1/agent-records/:id", params: "ID") { (p: ID) in
            guard let records else { throw APIError.unavailable("this host has no agent records") }
            try records.delete(p.id)
        }
    }

    private func registerAutomations() {
        let automations = api.automations
        add("automations.list", "GET /v1/automations", params: "AgentScopeRequest", result: "[Automation]") { (p: AgentScopeRequest) in try automations.list(agentId: p.agentId) }
        add("automations.get", "GET /v1/automations/:id", params: "ID", result: "Automation") { (p: ID) in try automations.get(p.id) }
        add("automations.status", "none", params: "ID", result: "AutomationStatus") { (p: ID) in try automations.status(p.id) }
        add("automations.history", "GET /v1/automations/:id/history", params: "AutomationHistoryRequest", result: "[AutomationRunInfo]") { (p: AutomationHistoryRequest) in try automations.history(p) }
        add("automations.logs", "GET /v1/automations/:id/log", params: "AutomationLogRequest", result: "[AutomationLogEntry]") { (p: AutomationLogRequest) in automations.logs(p) }
        add("automations.create", "POST /v1/automations", params: "CreateAutomationRequest", result: "Automation") { (p: CreateAutomationRequest) in try automations.create(p) }
        add("automations.update", "PATCH /v1/automations/:id", params: "UpdateAutomationRequest", result: "Automation") { (p: UpdateAutomationRequest) in try automations.update(p) }
        addVoid("automations.setEnabled", "POST /v1/automations/:id/pause, POST /v1/automations/:id/resume", params: "SetEnabled") { (p: SetEnabled) in try automations.setEnabled(p.id, p.enabled) }
        addVoid("automations.setSchedule", "none", params: "SetAutomationScheduleRequest") { (p: SetAutomationScheduleRequest) in try automations.setSchedule(p) }
        addVoid("automations.delete", "DELETE /v1/automations/:id", params: "ID") { (p: ID) in try automations.delete(p.id) }
        add("automations.runNow", "POST /v1/automations/:id/run-now", params: "ID", result: "AutomationRunResult") { (p: ID) in try await automations.runNow(p.id) }
        addVoid("automations.approve", "none", params: "ID") { (p: ID) in try automations.approve(p.id) }
        addVoid("automations.reject", "none", params: "ID") { (p: ID) in try automations.reject(p.id) }
    }

    private func registerChat() {
        // Every call names the agent whose chat it is about, or none for agent 1. `chat.threads` reads the disk, so it also lists the
        // threads of an agent that is not running.
        let api = api
        let chat = api.chat
        add("chat.snapshot", "GET /v1/chat/current", params: "AgentScopeRequest", result: "ChatSnapshot") { (p: AgentScopeRequest) in try api.chat(for: p.agentId).snapshot() }
        add("chat.status", "none", params: "AgentScopeRequest", result: "ChatStatus") { (p: AgentScopeRequest) in await try api.chat(for: p.agentId).status() }
        add("chat.messages", "none", params: "AgentScopeRequest", result: "[ChatItem]") { (p: AgentScopeRequest) in await try api.chat(for: p.agentId).messages() }
        add("chat.threads", "GET /v1/chat/threads", params: "AgentScopeRequest", result: "[ChatThreadInfo]") { (p: AgentScopeRequest) in try await chat.threads(agentId: p.agentId) }
        add("chat.send", "POST /v1/chat/current/messages", params: "SendChatRequest", result: "ChatSendResult") { (p: SendChatRequest) in try await api.chat(for: p.agentId).send(p) }
        add("chat.stop", "POST /v1/chat/current/stop", params: "AgentScopeRequest", result: "ChatStopResult") { (p: AgentScopeRequest) in await try api.chat(for: p.agentId).stop() }
        addVoid("chat.newChat", "POST /v1/chat/new", params: "AgentScopeRequest") { (p: AgentScopeRequest) in await try api.chat(for: p.agentId).newChat() }
        addVoid("chat.openThread", "POST /v1/chat/open/:id", params: "ChatOpenRequest") { (p: ChatOpenRequest) in try await api.chat(for: p.agentId).openThread(p.id) }
        addVoid("chat.decide", "POST /v1/chat/approvals/:id", params: "DecideApprovalRequest") { (p: DecideApprovalRequest) in try await api.chat(for: p.agentId).decide(p) }
        addVoid("chat.answerForm", "POST /v1/chat/forms/:id", params: "AnswerFormRequest") { (p: AnswerFormRequest) in try await api.chat(for: p.agentId).answerForm(p) }
        addVoid("chat.submitForm", "POST /v1/chat/forms/:id/submit", params: "ChatFormTarget") { (p: ChatFormTarget) in try await api.chat(for: p.agentId).submitForm(p.id) }
        addVoid("chat.skipForm", "POST /v1/chat/forms/:id/skip", params: "ChatFormTarget") { (p: ChatFormTarget) in try await api.chat(for: p.agentId).skipForm(p.id) }
        addVoid("chat.setMode", "none", params: "SetMode") { (p: SetMode) in await try api.chat(for: p.agentId).setMode(p.id) }
    }

    private func registerMemory() {
        add("memory.call", "none", params: "MemoryCall", result: "JSON") { [api] (p: MemoryCall) -> RemoteJSON in
            guard let memory = api.memory else { throw APIError.unavailable("Ghost's memory is not available right now") }
            guard memory.handles(p.name) else { throw APIError.notFound("no memory tool \"\(p.name)\"") }
            var arguments: [String: Any] = [:]
            if let object = p.arguments {
                guard case .object = object else { throw APIError.invalid("arguments must be an object") }
                arguments = (try? JSONSerialization.jsonObject(with: Self.wireEncoder.encode(object))) as? [String: Any] ?? [:]
            }
            switch memory.callTool(p.name, arguments, caller: p.caller) {
            case .success(let output):
                guard JSONSerialization.isValidJSONObject(["value": output]),
                      let data = try? JSONSerialization.data(withJSONObject: ["value": output]),
                      let wrapper = try? JSONDecoder().decode([String: RemoteJSON].self, from: data), let value = wrapper["value"]
                else { return .string(String(describing: output)) }
                return value
            case .failure(let failure):
                throw APIError.invalid(failure.message)
            }
        }
    }

    private func registerSettings() {
        let settings = api.settings
        add("settings.get", "GET /v1/settings", result: "Config") { settings.get() }
        add("settings.patch", "PATCH /v1/settings", params: "PatchSettingsRequest", result: "Config") { (p: PatchSettingsRequest) in try settings.patch(p) }
    }

    private func registerToday() {
        let today = api.today
        add("today.brief", "GET /v1/today", params: "BriefRequest", result: "Brief") { (p: BriefRequest) in today.brief(p) }
    }

    private func registerBubbles() {
        let bubbles = api.bubbles
        add("bubbles.list", "GET /v1/bubbles", result: "[BubbleInfo]") { bubbles.list() }
        addVoid("bubbles.dismiss", "none", params: "ID") { (p: ID) in try bubbles.dismiss(p.id) }
    }

    private func registerMeetings() {
        let meetings = api.meetings
        add("meetings.list", "GET /v1/meetings", result: "[MeetingInfo]") { meetings.list() }
        add("meetings.get", "none", params: "ID", result: "MeetingInfo") { (p: ID) in try meetings.get(p.id) }
        addVoid("meetings.delete", "DELETE /v1/meetings/:id", params: "ID") { (p: ID) in try meetings.delete(p.id) }
        addVoid("meetings.stop", "POST /v1/meetings/stop") { try meetings.stopRecording() }
    }

    private func registerNode() {
        let node = api.node
        add("node.info", "none", result: "NodeInfo") { () -> NodeInfo in
            guard let info = node.info() else { throw APIError.unavailable("this host has no node id") }
            return info
        }
    }

    private func registerSession() {
        let session = api.session
        add("session.hello", "none", params: "HelloRequest", result: "HelloResult") { (p: HelloRequest) -> HelloResult in
            guard SessionAPI.supportedProtocols.contains(p.protocolVersion) else {
                throw JSONRPCError(code: Self.code(for: .invalid), message: "protocol \(p.protocolVersion) is not supported",
                                   data: .object(["code": .string(APIError.Code.invalid.rawValue),
                                                  "supported": .array(SessionAPI.supportedProtocols.map { .int($0) })]))
            }
            guard let connection = Self.currentConnection else { throw APIError.unavailable("this transport has no connection to open a session on") }
            return try session.hello(p, connection: connection)
        }
    }

    private func registerScreen() {
        add("screen.ingest", "none", params: "ScreenIngestRequest", result: "ScreenIngestResult") { [api] (p: ScreenIngestRequest) -> ScreenIngestResult in
            guard let screen = api.screen else { throw APIError.unavailable("screen capture is not available on this host") }
            return try await screen.ingest(p)
        }
    }

    private func registerNotifications() {
        let notifications = api.notifications
        add("notifications.list", "none", params: "ListNotificationsRequest", result: "NotificationList") { (p: ListNotificationsRequest) in notifications.list(p) }
        add("notifications.get", "none", params: "ID", result: "NotificationItem") { (p: ID) in try notifications.get(p.id) }
        addVoid("notifications.markRead", "none", params: "ID") { (p: ID) in try notifications.markRead(p.id) }
        addVoid("notifications.markAllRead", "none") { notifications.markAllRead() }
    }
}
