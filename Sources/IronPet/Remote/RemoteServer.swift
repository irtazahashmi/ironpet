import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import HummingbirdWebSocket
import Logging
import NIOCore
import NIOTransportServices

/// What each request carries through the router: the device the token named, once the gate has checked it.
struct RemoteContext: RequestContext, WebSocketRequestContext {
    var coreContext: CoreRequestContextStorage
    let webSocket: WebSocketHandlerReference<Self>
    var device: RemoteDevice?

    /// Request bodies are capped at 1 MiB.
    var maxUploadSize: Int { RemoteServer.maxBody }

    init(source: Source) {
        coreContext = .init(source: source)
        webSocket = .init()
        device = nil
    }
}

/// Every request passes here first. It limits and checks the token, runs the route, makes errors one JSON shape, adds `Cache-Control:
/// no-store` and writes one access log row. The row has the method, the route template (`/v1/tasks/:id`), the status, the size and the
/// time. It never has the path, the query, a header or a body, so no token or code can reach it.
struct RemoteGate: RouterMiddleware {
    typealias Context = RemoteContext
    let service: RemoteService

    /// The two routes a device without a token may call.
    private static let open: Set<String> = ["/v1/pair", "/v1/pair/:id"]

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let started = ContinuousClock.now
        var context = context
        var response: Response
        do {
            response = try await dispatch(request, &context, next)
        } catch {
            response = RemoteServer.errorResponse(error)
        }
        // Asset routes set their own cache rule: the files hold no personal data and a hash names them for good.
        if response.headers[.cacheControl] == nil { response.headers[.cacheControl] = "no-store" }
        let elapsed = ContinuousClock.now - started
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        service.log(RemoteAccessRow(at: service.currentTime, deviceID: context.device?.id, method: request.method.rawValue,
                                    route: Self.template(context.endpointPath) ?? "-", status: Int(response.status.code),
                                    bytes: response.body.contentLength ?? 0, durationMs: ms))
        return response
    }

    /// The router names a parameter `{id}`. The log and the open-route list write it `:id`.
    static func template(_ path: String?) -> String? {
        path?.replacingOccurrences(of: #"\{(\w+)\}"#, with: ":$1", options: .regularExpression)
    }

    private func dispatch(_ request: Request, _ context: inout Context, _ next: (Request, Context) async throws -> Response) async throws -> Response {
        // Headers over 64 KiB are refused before anything reads them.
        let headerBytes = request.headers.reduce(0) { $0 + $1.name.rawName.utf8.count + $1.value.utf8.count + 4 }
        if headerBytes > RemoteServer.maxHeaders {
            return RemoteServer.error(431, "headers_too_large", "request headers are too large")
        }
        // Only the upload route takes a body past 1 MiB.
        let limit = Self.template(context.endpointPath) == RemoteServer.uploadRoute ? RemoteUploads.maxBytes : RemoteServer.maxBody
        if let length = request.headers[.contentLength].flatMap(Int.init), length > limit {
            return RemoteServer.error(413, "too_large", "request body is larger than \(limit) bytes")
        }
        if let path = Self.template(context.endpointPath), Self.open.contains(path) {
            return try await next(request, context)
        }
        switch service.authenticate(authorization: request.headers[.authorization], origin: request.headers[.xForwardedFor]) {
        case .device(let device):
            context.device = device
            return try await next(request, context)
        case .unauthorized:
            return RemoteServer.error(401, "unauthorized", "unauthorized")
        case .limited(let seconds):
            return RemoteServer.limited(seconds)
        }
    }
}

extension HTTPField.Name {
    static let xForwardedFor = HTTPField.Name("X-Forwarded-For")!
    static let pairingSecret = HTTPField.Name("X-Pairing-Secret")!
}

/// The remote API: Hummingbird with one port for REST and the event socket. It trusts nothing about the connection. Every route but
/// pairing needs a device token, and every route calls `IronPetAPI` like any other client.
///
/// Two listeners share the port number. One is plain HTTP on 127.0.0.1, for tests and for a front such as `tailscale serve`. The other is
/// HTTPS on the one network address the user chose, with the self-signed certificate of `RemoteIdentity`. Both run on Network.framework
/// (Hummingbird on `NIOTSEventLoopGroup`), whose TLS the HTTPS one uses, so the app bundles no TLS library. Nothing binds 0.0.0.0.
@MainActor
final class RemoteServer {
    nonisolated static let maxBody = 1 << 20
    nonisolated static let maxHeaders = 64 << 10
    nonisolated static let uploadRoute = "/v1/uploads"

    let service: RemoteService
    private let api: IronPetAPI
    private let uploads: RemoteUploads
    /// How often one message's `chat.item` event may reach a socket.
    var itemInterval: Duration = .milliseconds(100)
    private var tasks: [Task<Void, Never>] = []
    /// The port the listeners are bound to, while they run.
    private(set) var port: Int?
    /// The address the HTTPS listener is bound to, while it runs.
    private(set) var secureAddress: String?
    /// Hash of the certificate the HTTPS listener presents. It differs from the identity's after a rotation, until the server restarts.
    private(set) var servedFingerprint: String?
    /// The keychain that holds the HTTPS listener's identity, deleted when the listener stops.
    private(set) var keychain: RemoteTLSKeychain?

    init(api: IronPetAPI, service: RemoteService, uploads: RemoteUploads? = nil) {
        self.api = api
        self.service = service
        self.uploads = uploads ?? RemoteUploads()
    }

    var isRunning: Bool { !tasks.isEmpty }

    /// Starts listening on `port` (0 picks a free one, for tests), on 127.0.0.1 and, when `secureAddress` is set, on that address with TLS.
    /// With 127.0.0.1 itself as the secure address, only the HTTPS listener runs there, since two listeners cannot share the address.
    /// Throws when the port or the address is not available. Nothing keeps running after a throw.
    ///
    /// The HTTPS listener binds first, so a port of 0 is picked by it and the loopback listener takes the same number.
    func start(port requested: Int, secureAddress address: String? = nil) async throws {
        guard tasks.isEmpty else { return }
        precondition(address != "0.0.0.0", "the remote API never listens on every interface")
        var started: [Task<Void, Never>] = []
        var bound = requested
        var fingerprint: String?
        var tlsKeychain: RemoteTLSKeychain?
        do {
            if let address {
                // Network.framework would wait for a missing address instead of failing, so it is checked against the interfaces first.
                guard address == "127.0.0.1" || RemoteNetwork.interfaces().contains(where: { $0.ip == address }) else {
                    throw RemoteServerError.unavailable
                }
                let material = service.identity.material
                RemoteTLSKeychain.removeStale()
                let made = try RemoteTLSKeychain(material)
                made.keepUnlocked()
                tlsKeychain = made
                guard let options = TSTLSOptions.options(serverIdentity: .secIdentity(made.identity)) else { throw RemoteTLSKeychain.Failure.identity(0) }
                fingerprint = RemoteHash.hex(material.der)
                let secure = try await listen(host: address, port: requested, tls: options)
                started.append(secure.task)
                bound = secure.port
            }
            if address != "127.0.0.1" {
                let local = try await listen(host: "127.0.0.1", port: bound, tls: nil)
                started.append(local.task)
                bound = local.port
            }
        } catch {
            for task in started { task.cancel() }
            for task in started { await task.value }
            tlsKeychain?.close()
            throw error
        }
        port = bound
        secureAddress = address
        servedFingerprint = fingerprint
        keychain = tlsKeychain
        tasks = started
    }

    /// Closes the listeners and every event socket. Tokens stay valid.
    func stop() async {
        guard !tasks.isEmpty else { return }
        let running = tasks
        tasks = []
        port = nil
        secureAddress = nil
        servedFingerprint = nil
        service.closeAllSockets()
        for task in running { task.cancel() }
        for task in running { await task.value }
        keychain?.close()
        keychain = nil
    }

    enum RemoteServerError: Error, LocalizedError {
        case stopped
        case unavailable
        var errorDescription: String? {
            switch self {
            case .stopped: return "the remote API stopped before it was listening"
            case .unavailable: return "the address is not available on this Mac"
            }
        }
    }

    /// How long a listener may take to bind. Network.framework does not fail on an address the Mac does not have: it waits for it to appear.
    nonisolated static let bindTimeout: Duration = .seconds(5)

    /// Runs one listener and returns once it is bound.
    private func listen(host: String, port requested: Int, tls: TSTLSOptions?) async throws -> (port: Int, task: Task<Void, Never>) {
        let (started, report) = AsyncStream<Result<Int, Error>>.makeStream()
        let app = try makeApplication(host: host, port: requested, tls: tls) { report.yield(.success($0)) }
        let running = Task.detached {
            do {
                try await app.runService()
                report.yield(.failure(RemoteServerError.stopped))
            } catch {
                report.yield(.failure(error))
            }
            report.finish()
        }
        let timeout = Task.detached {
            try? await Task.sleep(for: Self.bindTimeout)
            if !Task.isCancelled { report.yield(.failure(RemoteServerError.unavailable)) }
        }
        defer { timeout.cancel() }
        for await result in started {
            switch result {
            case .success(let bound): return (bound, running)
            case .failure(let error):
                // Not awaited: a Network.framework listener that waits for its address ignores cancellation until it gets one. `start`
                // checks the address first, so this happens only when it disappears in between.
                running.cancel()
                throw error
            }
        }
        throw RemoteServerError.stopped
    }

    // MARK: Application

    private func makeApplication(host: String, port: Int, tls: TSTLSOptions?, onRunning: @escaping @Sendable (Int) -> Void) throws -> some ApplicationProtocol {
        let router = Router(context: RemoteContext.self)
        router.add(middleware: RemoteGate(service: service))
        addRoutes(to: router)
        let upgrades = Router(context: RemoteContext.self)
        addEventSocket(to: upgrades)
        // TLS options apply only on a Network.framework event loop group.
        var configuration = tls.map { ApplicationConfiguration(address: .hostname(host, port: port), tlsOptions: $0) }
            ?? ApplicationConfiguration(address: .hostname(host, port: port))
        configuration.serverName = nil
        // The server's own logger stays silent: its messages carry request paths and error text, which the access log keeps out on purpose.
        let silent = Logger(label: "ironpet.remote", factory: { _ in SwiftLogNoOpLogHandler() })
        let server = HTTPServerBuilder.http1WebSocketUpgrade(webSocketRouter: upgrades,
                                                             configuration: .init(maxFrameSize: 1 << 14, autoPing: .enabled(timePeriod: .seconds(20))))
        // Both listeners run on Network.framework. With a plain socket on 127.0.0.1, Network.framework refused to bind the network address
        // while a connection to the old loopback listener was still closing, which a restart after a rotation or an address change hits.
        let group: EventLoopGroupProvider = .shared(NIOTSEventLoopGroup.singleton)
        return Application(router: router, server: server, configuration: configuration, onServerRunning: { channel in onRunning(channel.localAddress?.port ?? port) },
                           eventLoopGroupProvider: group, logger: silent)
    }

    // MARK: Routes

    private func addRoutes(to router: Router<RemoteContext>) {
        let service = service
        router.post("/v1/pair") { request, context -> Response in
            let body = try await Self.object(request, context)
            let key = body["device_public_key"] as? String
            switch service.pair(code: body["code"] as? String ?? "", deviceName: body["device_name"] as? String ?? "", publicKey: key) {
            case .accepted(let accepted):
                return Self.json(202, ["pairing_id": accepted.pairingID, "secret": accepted.secret, "expires_in": accepted.expiresIn])
            case .invalid(let message): return Self.error(400, "invalid", message)
            case .unauthorized: return Self.error(401, "unauthorized", "unauthorized")
            case .limited(let seconds): return Self.limited(seconds)
            }
        }
        router.get("/v1/pair/:id") { request, context -> Response in
            let id = Self.parameter(context, "id")
            switch service.poll(id: id, secret: request.headers[.pairingSecret] ?? "") {
            case .pending: return Self.json(200, ["status": "pending"])
            case .denied: return Self.json(200, ["status": "denied"])
            case .expired: return Self.json(200, ["status": "expired"])
            case .allowed(let token, let deviceID): return Self.json(200, ["status": "allowed", "token": token, "device_id": deviceID])
            case .gone: return Self.error(410, "gone", "the token was already handed out")
            case .unauthorized: return Self.error(401, "unauthorized", "unauthorized")
            case .limited(let seconds): return Self.limited(seconds)
            }
        }
        router.get("/v1/devices/me") { _, context -> Response in
            guard let device = context.device else { return Self.error(401, "unauthorized", "unauthorized") }
            return Self.json(200, Self.describe(device))
        }
        router.delete("/v1/devices/me") { _, context -> Response in
            guard let device = context.device else { return Self.error(401, "unauthorized", "unauthorized") }
            service.revoke(device.id)
            return Self.json(200, ["revoked": true])
        }
        // A request that reaches here without an upgrade, or whose upgrade the socket router refused.
        router.get("/v1/events") { _, context -> Response in
            guard let device = context.device else { return Self.error(401, "unauthorized", "unauthorized") }
            if service.socketCount(device: device.id) >= RemoteService.socketsPerDevice { return Self.limited(5) }
            return Self.error(426, "upgrade_required", "this route is a WebSocket")
        }

        router.get("/v1/tasks") { [self] request, context in
            let query = Self.query(request)
            return try await self.call(context) { try $0.list(query: query) }
        }
        router.post("/v1/tasks") { [self] request, context in
            let body = try await Self.object(request, context)
            return try await self.call(context, status: 201) { try $0.create(body) }
        }
        router.get("/v1/tasks/:id") { [self] _, context in
            let id = Self.parameter(context, "id")
            return try await self.call(context) { try $0.get(id) }
        }
        router.patch("/v1/tasks/:id") { [self] request, context in
            let id = Self.parameter(context, "id")
            let body = try await Self.object(request, context)
            return try await self.call(context) { try $0.update(id, body) }
        }
        router.post("/v1/tasks/:id/close") { [self] request, context in
            let id = Self.parameter(context, "id")
            let body = try await Self.object(request, context)
            return try await self.call(context) { try $0.close(id, body) }
        }
        router.delete("/v1/tasks/:id") { [self] _, context in
            let id = Self.parameter(context, "id")
            return try await self.call(context) { try $0.delete(id) }
        }
        router.get("/v1/suggestions") { [self] _, context in
            try await self.call(context) { try $0.suggestions() }
        }
        router.post("/v1/suggestions/:id/accept") { [self] request, context in
            let id = Self.parameter(context, "id")
            let body = try await Self.object(request, context)
            return try await self.call(context) { try $0.accept(id, body) }
        }
        router.post("/v1/suggestions/:id/reject") { [self] request, context in
            let id = Self.parameter(context, "id")
            let body = try await Self.object(request, context)
            return try await self.call(context) { try $0.reject(id, body) }
        }
        addResourceRoutes(to: router)
        addChatRoutes(to: router)
        addAutomationRoutes(to: router)
        addMeetingRoutes(to: router)
        addSettingsRoutes(to: router)
        addScreenRoutes(to: router)
    }

    /// Screen captures (phase 5). Every route needs the `screen` scope, which only the Mac grants, and counts against 200 requests an hour.
    private func addScreenRoutes(to router: Router<RemoteContext>) {
        router.get("/v1/screen/status") { [self] _, context in await self.screenCall(context) { await RemoteScreen(screen: $0).status() } }
        router.get("/v1/screen/changes") { [self] request, context in
            let query = Self.query(request)
            return await self.screenCall(context) { try RemoteScreen(screen: $0).changes(query: query) }
        }
        router.get("/v1/screen/captures/:id") { [self] request, context in
            let id = Self.parameter(context, "id"), query = Self.query(request)
            return await self.screenCall(context) { try RemoteScreen(screen: $0).capture(id, query: query) }
        }
        router.get("/v1/screen/search") { [self] request, context in
            let query = Self.query(request)
            return await self.screenCall(context) { try RemoteScreen(screen: $0).search(query: query) }
        }
        router.post("/v1/screen/pause") { [self] request, context in
            let body = try await Self.object(request, context)
            return await self.screenCall(context) { try await RemoteScreen(screen: $0).pause(body) }
        }
    }

    /// Checks the device's `screen` scope (403) and its hourly limit (429), then runs the call on the main actor.
    private func screenCall(_ context: RemoteContext, _ body: @MainActor (ScreenAPI) async throws -> [String: Any]) async -> Response {
        guard let device = context.device else { return Self.error(401, "unauthorized", "unauthorized") }
        switch service.authorizeScreen(device) {
        case .forbidden: return Self.error(403, "forbidden", "This device may not read the screen. Turn on Screen text for it in Settings → Devices on the Mac.")
        case .limited(let seconds): return Self.limited(seconds)
        case .allowed: break
        }
        guard let screen = api.screen else { return Self.error(503, "unavailable", "screen capture is not available") }
        do { return Self.json(200, try await body(screen)) } catch { return Self.errorResponse(RemoteFailure(error)) }
    }

    /// Automations (phase 4). The device is the author of what it creates or changes, so risky automations wait for Approve on the Mac.
    private func addAutomationRoutes(to router: Router<RemoteContext>) {
        router.get("/v1/automations") { [self] _, context in await self.phoneFour(context) { RemoteAutomations(api: $0, device: $1).list() } }
        router.post("/v1/automations") { [self] request, context in
            let body = try await Self.object(request, context)
            return await self.phoneFour(context, status: 201) { try RemoteAutomations(api: $0, device: $1).create(body) }
        }
        router.post("/v1/automations/request") { [self] request, context in
            let body = try await Self.object(request, context)
            return await self.phoneFour(context) { try await RemoteAutomations(api: $0, device: $1).request(body) }
        }
        router.get("/v1/automations/:id") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.phoneFour(context) { try RemoteAutomations(api: $0, device: $1).get(id) }
        }
        router.patch("/v1/automations/:id") { [self] request, context in
            let id = Self.parameter(context, "id")
            let body = try await Self.object(request, context)
            return await self.phoneFour(context) { try RemoteAutomations(api: $0, device: $1).update(id, body) }
        }
        router.delete("/v1/automations/:id") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.phoneFour(context) { try RemoteAutomations(api: $0, device: $1).delete(id) }
        }
        router.get("/v1/automations/:id/history") { [self] request, context in
            let id = Self.parameter(context, "id"), query = Self.query(request)
            return await self.phoneFour(context) { try RemoteAutomations(api: $0, device: $1).history(id, query: query) }
        }
        router.get("/v1/automations/:id/log") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.phoneFour(context) { try RemoteAutomations(api: $0, device: $1).log(id) }
        }
        router.post("/v1/automations/:id/pause") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.phoneFour(context) { try RemoteAutomations(api: $0, device: $1).pause(id) }
        }
        router.post("/v1/automations/:id/resume") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.phoneFour(context) { try RemoteAutomations(api: $0, device: $1).resume(id) }
        }
        router.post("/v1/automations/:id/run-now") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.phoneFour(context) { try await RemoteAutomations(api: $0, device: $1).runNow(id) }
        }
    }

    /// Meetings (phase 4). There is no route that starts a recording or serves audio.
    private func addMeetingRoutes(to router: Router<RemoteContext>) {
        router.get("/v1/meetings") { [self] _, context in await self.phoneFour(context) { api, _ in RemoteMeetings(api: api).list() } }
        router.get("/v1/meetings/state") { [self] _, context in await self.phoneFour(context) { api, _ in RemoteMeetings(api: api).state() } }
        router.post("/v1/meetings/stop") { [self] _, context in await self.phoneFour(context) { api, _ in try RemoteMeetings(api: api).stop() } }
        router.get("/v1/meetings/:id/summary") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.phoneFour(context) { api, _ in try await RemoteMeetings(api: api).text(id, .summary) }
        }
        router.get("/v1/meetings/:id/transcript") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.phoneFour(context) { api, _ in try await RemoteMeetings(api: api).text(id, .transcript) }
        }
        router.post("/v1/meetings/:id/regenerate") { [self] request, context in
            let id = Self.parameter(context, "id"), mode = Self.query(request)["mode"]?.first
            return await self.phoneFour(context, status: 202) { api, _ in try RemoteMeetings(api: api).regenerate(id, mode: mode) }
        }
        router.post("/v1/meetings/:id/ask") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.phoneFour(context) { api, _ in try RemoteMeetings(api: api).ask(id) }
        }
        router.delete("/v1/meetings/:id") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.phoneFour(context) { api, _ in try RemoteMeetings(api: api).delete(id) }
        }
    }

    /// Settings, the pet gallery and usage (phase 4).
    private func addSettingsRoutes(to router: Router<RemoteContext>) {
        router.get("/v1/settings") { [self] _, context in await self.phoneFour(context) { api, _ in RemotePhoneSettings(api: api).get() } }
        router.patch("/v1/settings") { [self] request, context in
            let body = try await Self.object(request, context)
            return await self.phoneFour(context) { api, _ in try await RemotePhoneSettings(api: api).patch(body) }
        }
        router.get("/v1/settings/pets") { [self] _, context in await self.phoneFour(context) { api, _ in await RemotePhoneSettings(api: api).pets() } }
        router.post("/v1/settings/pet") { [self] request, context in
            let body = try await Self.object(request, context)
            return await self.phoneFour(context) { api, _ in try await RemotePhoneSettings(api: api).selectPet(body) }
        }
        router.get("/v1/usage") { [self] request, context in
            let range = Self.query(request)["range"]?.first
            return await self.phoneFour(context) { api, _ in try RemotePhoneSettings(api: api).usage(range: range) }
        }
    }

    /// Runs a phase 4 call on the main actor with the API and the calling device's id.
    private func phoneFour(_ context: RemoteContext, status: Int = 200, _ body: @MainActor (IronPetAPI, String) async throws -> [String: Any]) async -> Response {
        guard let device = context.device else { return Self.error(401, "unauthorized", "unauthorized") }
        do { return Self.json(status, try await body(api, device.id)) } catch { return Self.errorResponse(RemoteFailure(error)) }
    }

    /// The shared chat and uploads (phase 3).
    private func addChatRoutes(to router: Router<RemoteContext>) {
        router.get("/v1/chat/current") { [self] _, context in await self.chat(context) { await $0.current() } }
        router.get("/v1/chat/messages/:id") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.chat(context) { try await $0.message(id) }
        }
        router.get("/v1/chat/threads") { [self] _, context in await self.chat(context) { await $0.threads() } }
        router.get("/v1/chat/threads/:id") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.chat(context) { try await $0.thread(id) }
        }
        router.post("/v1/chat/current/messages") { [self] request, context in
            let body = try await Self.object(request, context)
            return await self.chat(context) { try await $0.send(body) }
        }
        router.post("/v1/chat/current/stop") { [self] _, context in await self.chat(context) { await $0.stop() } }
        router.post("/v1/chat/open/:id") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.chat(context) { try await $0.open(id) }
        }
        router.post("/v1/chat/new") { [self] _, context in await self.chat(context) { try await $0.newChat() } }
        router.post("/v1/chat/approvals/:id") { [self] request, context in
            let id = Self.parameter(context, "id")
            let body = try await Self.object(request, context)
            return await self.chat(context) { try await $0.decide(id, body) }
        }
        router.post("/v1/chat/forms/:id") { [self] request, context in
            let id = Self.parameter(context, "id")
            let body = try await Self.object(request, context)
            return await self.chat(context) { try await $0.answer(id, body) }
        }
        router.post("/v1/chat/forms/:id/submit") { [self] request, context in
            let id = Self.parameter(context, "id")
            let body = try await Self.object(request, context)
            return await self.chat(context) { try await $0.submit(id, body) }
        }
        router.post("/v1/chat/forms/:id/skip") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.chat(context) { try await $0.skip(id) }
        }
        // One photo or file as the raw body. `X-File-Name` is its name, percent encoded. Only this route may carry 20 MiB.
        router.post("/v1/uploads") { [self] request, context in
            guard let device = context.device else { return Self.error(401, "unauthorized", "unauthorized") }
            let buffer = try await request.body.collect(upTo: RemoteUploads.maxBytes)
            guard buffer.readableBytes > 0 else { return Self.error(400, "invalid", "the upload is empty") }
            let data = Data(buffer.readableBytesView)
            let raw = request.headers[.init("X-File-Name")!] ?? ""
            let name = raw.removingPercentEncoding ?? raw
            do {
                let saved = try await self.uploads.save(data, fileName: name, device: device.id)
                return Self.json(201, ["id": saved.id, "file_name": saved.name, "stored_name": saved.stored, "bytes": data.count])
            } catch {
                return Self.errorResponse(RemoteFailure(error))
            }
        }
    }

    private func chat(_ context: RemoteContext, status: Int = 200, _ body: @MainActor (RemoteChat) async throws -> [String: Any]) async -> Response {
        guard let device = context.device else { return Self.error(401, "unauthorized", "unauthorized") }
        do { return Self.json(status, try await body(RemoteChat(api: api, device: device.id, uploads: uploads))) } catch {
            return Self.errorResponse(RemoteFailure(error))
        }
    }

    /// Pet, bubbles, agents, alerts, today and assets (phase 2).
    private func addResourceRoutes(to router: Router<RemoteContext>) {
        router.get("/v1/pet") { [self] _, context in await self.resources(context) { await $0.pet() } }
        router.post("/v1/pet/tricks/:name") { [self] _, context in
            let name = Self.parameter(context, "name")
            return await self.resources(context) { try $0.trick(name) }
        }
        router.get("/v1/bubbles") { [self] _, context in await self.resources(context) { $0.bubbles() } }
        router.post("/v1/bubbles/:id/actions/:action") { [self] _, context in
            let id = Self.parameter(context, "id"), action = Self.parameter(context, "action")
            return await self.resources(context) { try $0.press(bubble: id, action: action) }
        }
        router.get("/v1/agents") { [self] _, context in await self.resources(context) { $0.agents() } }
        router.get("/v1/agents/:id") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.resources(context) { try $0.agent(id) }
        }
        router.post("/v1/agents/:id/acknowledge") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.resources(context) { try $0.acknowledge(id) }
        }
        router.post("/v1/agents/:id/ask") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.resources(context) { try await $0.askAboutAgent(id) }
        }
        router.get("/v1/alerts") { [self] _, context in await self.resources(context) { $0.alerts() } }
        router.post("/v1/alerts/dismiss-all") { [self] _, context in await self.resources(context) { $0.dismissAllAlerts() } }
        router.post("/v1/alerts/:id/dismiss") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.resources(context) { try $0.dismissAlert(id) }
        }
        router.post("/v1/alerts/:id/ask") { [self] _, context in
            let id = Self.parameter(context, "id")
            return await self.resources(context) { try await $0.askAboutAlert(id) }
        }
        router.get("/v1/today") { [self] request, context in
            let kind = Self.query(request)["kind"]?.first
            return await self.resources(context) { try $0.today(kind: kind) }
        }
        router.get("/v1/assets/manifest") { [self] _, context in await self.resources(context) { await $0.manifest() } }
        router.get("/v1/assets/:sha256") { [self] request, context in
            let hash = Self.parameter(context, "sha256").lowercased()
            return await self.asset(hash, request: request, context)
        }
    }

    /// A file by content hash. The hash is its name for good, so the answer is cacheable for a year and a repeat request with the same
    /// `If-None-Match` gets 304.
    private func asset(_ hash: String, request: Request, _ context: RemoteContext) async -> Response {
        guard context.device != nil else { return Self.error(401, "unauthorized", "unauthorized") }
        let etag = "\"\(hash)\""
        do {
            let found = try await RemoteResources(api: api, device: context.device?.id ?? "").asset(sha256: hash)
            var headers: HTTPFields = [.cacheControl: "private, max-age=31536000, immutable", .eTag: etag]
            if request.headers[.ifNoneMatch] == etag { return Response(status: .notModified, headers: headers) }
            headers[.contentType] = found.contentType
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: found.data)))
        } catch {
            return Self.errorResponse(RemoteFailure(error))
        }
    }

    /// Runs a call on `IronPetAPI` on the main actor and turns its result or error into a response.
    private func resources(_ context: RemoteContext, status: Int = 200, _ body: @MainActor (RemoteResources) async throws -> [String: Any]) async -> Response {
        guard let device = context.device else { return Self.error(401, "unauthorized", "unauthorized") }
        do { return Self.json(status, try await body(RemoteResources(api: api, device: device.id))) } catch {
            return Self.errorResponse(RemoteFailure(error))
        }
    }

    /// Runs a task call on the main actor, as every other client of `IronPetAPI` does, and turns its result or error into a response.
    private func call(_ context: RemoteContext, status: Int = 200, _ body: @MainActor (RemoteTasks) throws -> [String: Any]) async throws -> Response {
        guard let device = context.device else { return Self.error(401, "unauthorized", "unauthorized") }
        let api = api
        return await MainActor.run {
            do { return Self.json(status, try body(RemoteTasks(api: api, by: "remote:\(device.id)"))) } catch {
                return Self.errorResponse(RemoteFailure(error))
            }
        }
    }

    // MARK: Event socket

    private func addEventSocket(to router: Router<RemoteContext>) {
        let service = service
        let api = api
        let interval = itemInterval
        router.ws("/v1/events", shouldUpgrade: { request, _ in
            // The same checks as REST, without counting a failure: a refused upgrade falls through to the REST router, which counts it once.
            let header = request.headers[.authorization]
            guard case .device(let device) = service.authenticate(authorization: header, origin: nil, count: false),
                  service.socketCount(device: device.id) < RemoteService.socketsPerDevice,
                  case .device = service.authenticate(authorization: header, origin: request.headers[.xForwardedFor]) else { return .dontUpgrade }
            service.log(RemoteAccessRow(at: Date(), deviceID: device.id, method: "GET", route: "/v1/events", status: 101, bytes: 0, durationMs: 0))
            return .upgrade([:])
        }) { inbound, outbound, context in
            let request = context.request
            guard case .device(let device) = service.authenticate(authorization: request.headers[.authorization], origin: nil, count: false) else { return }
            let since = request.uri.queryParameters["since"].flatMap { Int($0) }
            let (frames, send) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(2000))
            guard let socket = service.openSocket(device: device.id, close: { send.finish() }) else { return }
            defer { service.socketClosed(socket) }
            let (subscription, throttle) = await MainActor.run { () -> (APIEventBus.Subscription, RemoteEventThrottle) in
                let bus = api.events
                send.yield(Self.text(["kind": "hello", "seq": bus.lastSeq]))
                let gap = since.map { bus.replay(after: $0).gap } ?? false
                if gap { send.yield(Self.text(["kind": "resync", "seq": bus.lastSeq])) }
                // A streamed reply changes one message many times a second. The phone reads it again on each event, so it gets at most
                // one `chat.item` per message per interval, and the last one after the stream pauses.
                let throttle = RemoteEventThrottle(interval: interval) { send.yield(Self.text(Self.describe($0))) }
                return (bus.subscribe(after: gap ? nil : since) { throttle.push($0) }, throttle)
            }
            defer { Task { @MainActor in subscription.cancel(); throttle.cancel() } }
            // Reading keeps the library answering pings. A close from the device or a revoke ends the stream and with it the socket.
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do { for try await _ in inbound {} } catch {}
                    send.finish()
                }
                group.addTask {
                    for await frame in frames {
                        do { try await outbound.write(.text(frame)) } catch { break }
                    }
                }
                await group.next()
                group.cancelAll()
            }
        }
    }

    // MARK: JSON

    private nonisolated static func describe(_ event: APIEvent) -> [String: Any] {
        var object: [String: Any] = ["seq": event.seq, "at": ISO8601DateFormatter().string(from: event.at), "kind": event.kind.rawValue]
        if let id = event.id { object["id"] = id }
        return object
    }

    private nonisolated static func describe(_ device: RemoteDevice) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var object: [String: Any] = ["id": device.id, "name": device.name, "created": iso.string(from: device.created)]
        if let seen = device.lastSeen { object["last_seen"] = iso.string(from: seen) }
        return object
    }

    private nonisolated static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    private nonisolated static func text(_ object: Any) -> String { String(decoding: data(object), as: UTF8.self) }

    nonisolated static func json(_ status: Int, _ object: Any) -> Response {
        let bytes = data(object)
        return Response(status: .init(code: status), headers: [.contentType: "application/json; charset=utf-8"], body: .init(byteBuffer: ByteBuffer(bytes: bytes)))
    }

    nonisolated static func error(_ status: Int, _ code: String, _ message: String) -> Response {
        json(status, ["error": ["code": code, "message": message]])
    }

    nonisolated static func limited(_ seconds: Int) -> Response {
        var response = error(429, "rate_limited", "too many requests")
        response.headers[.retryAfter] = String(max(1, seconds))
        return response
    }

    /// Everything a route or the router throws becomes `{"error":{"code","message"}}`. Unknown errors say nothing about the cause.
    nonisolated static func errorResponse(_ error: Error) -> Response {
        if let failure = error as? RemoteFailure { return Self.error(failure.status, failure.code, failure.message) }
        if let http = error as? HTTPResponseError {
            let code = http.status.code
            let names = [400: "invalid", 404: "not_found", 405: "method_not_allowed", 413: "too_large", 415: "unsupported", 422: "invalid"]
            return Self.error(Int(code), names[Int(code)] ?? "failed", http.status.reasonPhrase)
        }
        return Self.error(500, "failed", "internal error")
    }

    /// The body as a JSON object. An empty body is an empty object.
    nonisolated static func object(_ request: Request, _ context: RemoteContext) async throws -> [String: Any] {
        let buffer = try await request.body.collect(upTo: context.maxUploadSize)
        guard buffer.readableBytes > 0 else { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(buffer.readableBytesView))) as? [String: Any] else {
            throw RemoteFailure.invalid("the body must be a JSON object")
        }
        return object
    }

    /// A path parameter with its percent escapes decoded, as the phone's URL encoder writes a trick named "Drink water".
    nonisolated static func parameter(_ context: RemoteContext, _ name: String) -> String {
        let raw = context.parameters.get(name) ?? ""
        return raw.removingPercentEncoding ?? raw
    }

    nonisolated static func query(_ request: Request) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (key, value) in request.uri.queryParameters { result[String(key), default: []].append(String(value)) }
        return result
    }
}
