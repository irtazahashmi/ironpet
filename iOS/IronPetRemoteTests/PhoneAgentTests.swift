import IronPetKit
import Security
import XCTest
@testable import IronPetRemote

/// Answers each request of the agent loop with the next scripted stream.
final class ScriptedAgentTransport: AgentTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String]
    private(set) var requests: [AgentHTTPRequest] = []
    init(_ answers: [String]) { self.answers = answers }

    func lines(for request: AgentHTTPRequest) -> AsyncThrowingStream<String, Error> {
        lock.lock(); requests.append(request); let text = answers.isEmpty ? "" : answers.removeFirst(); lock.unlock()
        return AsyncThrowingStream { continuation in
            for line in text.components(separatedBy: "\n") { continuation.yield(line) }
            continuation.finish()
        }
    }
}

private struct NoCalendar: DeviceCalendarHost {
    func events(from start: Date, to end: Date) async throws -> [CalendarEntry] { [] }
    func addReminder(title: String, due: Date?) async throws {}
}

private struct NoFetcher: WebFetching { func fetch(_ url: URL) async throws -> String { "" } }

/// The phone agent's settings, queue and registration against the mock Mac.
@MainActor
final class PhoneAgentTests: XCTestCase {
    var server: MockIronPetServer!
    var directory: URL!
    var defaults: UserDefaults!
    var suite: String!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("phone-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "phone-agent-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        server.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private var queueFile: URL { directory.appendingPathComponent("queue.json") }

    private func model(reachable: Bool = true, keys: MemoryAgentKeyStore = MemoryAgentKeyStore(), transport: any AgentTransport = ScriptedAgentTransport([])) -> PhoneAgentModel {
        let base = reachable ? server.baseURL : URL(string: "http://127.0.0.1:1")!
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: base), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        return PhoneAgentModel(client: client, events: events, keys: keys, settings: PhoneAgentSettings(defaults: defaults), queue: FileInboxQueueStore(url: queueFile),
                               transport: transport, fetcher: NoFetcher(), calendar: NoCalendar(), onUnauthorized: {})
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(20)
        while Date() < end, !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: S3

    func testTheApiKeyIsOnlyInTheKeychain() async throws {
        let service = "dev.ironpet.test.agent.\(UUID().uuidString)"
        let keychain = KeychainAgentKeyStore(service: service)
        defer { keychain.removeKey(for: .anthropic) }
        let secret = "sk-ant-secret-\(UUID().uuidString)"
        let model = model(keys: MemoryAgentKeyStore())
        // The model saves through the same store protocol the app gives it, so this run uses the Keychain one.
        let real = PhoneAgentModel(client: IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token),
                                   events: SharedEventSource(EventConnection(client: IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token))),
                                   keys: keychain, settings: PhoneAgentSettings(defaults: defaults), queue: FileInboxQueueStore(url: queueFile),
                                   transport: ScriptedAgentTransport([]), fetcher: NoFetcher(), calendar: NoCalendar(), onUnauthorized: {})
        _ = model
        try await real.save(provider: .anthropic, model: "claude-sonnet-5-5", key: secret)
        _ = await real.inbox.add(title: "Call Tom")

        // In the Keychain, on this device only, not synchronized.
        XCTAssertEqual(keychain.apiKey(for: .anthropic), secret)
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "anthropic",
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var found: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &found), errSecSuccess)
        let attributes = try XCTUnwrap(found as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        found = nil
        _ = SecItemCopyMatching(query as CFDictionary, &found)
        XCTAssertEqual((found as? [String: Any])?[kSecAttrSynchronizable as String] as? Bool ?? false, false)

        // Not in UserDefaults, the app's standard ones or the suite the settings use.
        for store in [defaults!, UserDefaults.standard] {
            XCTAssertFalse("\(store.dictionaryRepresentation())".contains(secret), "the key is in UserDefaults")
        }
        XCTAssertEqual(defaults.string(forKey: PhoneAgentSettings.providerKey), "anthropic", "the settings were written, without the key")
        // Not in a file the app writes: the queue, or anything under the folders the app keeps data in.
        let queue = try String(contentsOf: queueFile, encoding: .utf8)
        XCTAssertFalse(queue.contains(secret))
        for root in [FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
                     FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0], directory!] {
            for case let file as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])! {
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2_000_000, let data = try? Data(contentsOf: file) else { continue }
                XCTAssertNil(data.range(of: Data(secret.utf8)), "the key is in \(file.path)")
            }
        }
        // Not in what the Mac is sent.
        await waitUntil { !self.server.phoneAgentRegistrations.isEmpty }
        XCTAssertFalse("\(server.phoneAgentRegistrations)".contains(secret))
        XCTAssertFalse("\(server.addedByPhone)".contains(secret))
    }

    func testRemovingTheKeyLeavesTheAgentUnconfigured() async throws {
        let keys = MemoryAgentKeyStore()
        let model = model(keys: keys)
        try await model.save(provider: .anthropic, model: "", key: "sk-x")
        XCTAssertTrue(model.hasKey)
        model.removeKey()
        XCTAssertFalse(model.hasKey)
        XCTAssertNil(keys.apiKey(for: .anthropic))
        XCTAssertEqual(model.registration, .notConfigured)
    }

    // MARK: S5

    func testAFreshInstallRegistersNothingUntilAKeyIsSet() async throws {
        let model = model()
        await model.syncWithMac()
        XCTAssertEqual(model.registration, .notConfigured)
        XCTAssertTrue(server.phoneAgentRegistrations.isEmpty)
        XCTAssertEqual(model.config, AgentConfig(provider: .anthropic), "Anthropic and the current Sonnet are the defaults")
    }

    func testAConfiguredPhoneAgentRegistersWithTheMacAsAnAgentOfTheNode() async throws {
        let model = model()
        try await model.save(provider: .openai, model: "gpt-test", key: "sk-x")
        guard case .registered(let record) = model.registration else { return XCTFail("\(model.registration)") }
        XCTAssertEqual(record.name, PhoneAgentModel.agentName)
        XCTAssertEqual(record.deviceID, server.deviceID)
        XCTAssertTrue(record.runsOnPhone)
        let sent = try XCTUnwrap(server.phoneAgentRegistrations.last)
        XCTAssertEqual(sent["provider"] as? String, "openai")
        XCTAssertEqual(sent["model"] as? String, "gpt-test")
        XCTAssertEqual(sent["name"] as? String, "Ghost on iPhone")
    }

    func testARegistrationThatCannotReachTheMacWaitsAndIsSentWhenItAnswers() async throws {
        let keys = MemoryAgentKeyStore()
        try keys.setKey("sk-x", for: .anthropic)
        let offline = model(reachable: false, keys: keys)
        await offline.syncWithMac()
        XCTAssertEqual(offline.registration, .pending("Waiting for the Mac"))
        let online = model(keys: keys)
        await online.syncWithMac()
        guard case .registered = online.registration else { return XCTFail("\(online.registration)") }
        XCTAssertEqual(server.phoneAgentRegistrations.count, 1)
    }

    func testTheChatPickerNeverOffersAnAgentThatRunsOnAPhone() async throws {
        server.agentRecords = [RemoteAgentRecord(id: "agent_default", name: "Ghost"), RemoteAgentRecord(id: "agent_phone", number: 2, name: "Ghost on iPhone", agentCli: "anthropic", deviceID: "dev")]
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client))
        let main = ChatModel(client: client, events: events, onUnauthorized: {})
        let chats = AgentChatsModel(client: client, events: events, main: main, makeChat: { _ in ChatModel(client: client, events: events, onUnauthorized: {}) }, onUnauthorized: {})
        await chats.reload()
        XCTAssertEqual(chats.records.map(\.id), ["agent_default"])
        XCTAssertFalse(chats.showsAgents)
    }

    // MARK: S1, the phone's side

    func testAReminderAddedWhileTheMacIsOutOfReachIsDeliveredWhenItIsReachable() async throws {
        let keys = MemoryAgentKeyStore()
        try keys.setKey("sk-x", for: .anthropic)
        let call = """
            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"inbox_add","input":{}}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"title\\":\\"Call Tom\\",\\"due\\":\\"2026-11-27\\"}"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":0}

            event: message_stop
            data: {"type":"message_stop"}

            """
        let answer = """
            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Added. The Mac gets it later."}}

            event: message_stop
            data: {"type":"message_stop"}

            """
        let offline = model(reachable: false, keys: keys, transport: ScriptedAgentTransport([call, answer]))
        offline.send("remind me to call Tom tomorrow")
        await waitUntil { !offline.isRunning && offline.messages.contains { $0.role == .assistant && !$0.text.isEmpty } }
        XCTAssertEqual(offline.messages.last?.text, "Added. The Mac gets it later.")
        XCTAssertEqual(offline.waiting.map(\.title), ["Call Tom"], "the item waits on the phone")
        XCTAssertTrue(server.addedByPhone.isEmpty)
        let stored = try String(contentsOf: queueFile, encoding: .utf8)
        XCTAssertTrue(stored.contains("Call Tom"), "the queue is on disk, so an app restart keeps it")

        // The Mac comes back: a new launch reads the same file and sends the item.
        let online = model(keys: keys)
        await online.syncWithMac()
        XCTAssertEqual(server.addedByPhone.compactMap { $0["title"] as? String }, ["Call Tom"])
        XCTAssertEqual(server.addedByPhone.first?["due"] as? String, "2026-11-27")
        XCTAssertTrue((server.addedByPhone.first?["id"] as? String)?.hasPrefix("phone-") == true)
        XCTAssertTrue(server.suggestions.contains { $0.title == "Call Tom" }, "the item is in the Mac's inbox")
        XCTAssertTrue(online.waiting.isEmpty)

        // Sending again, as a lost answer would, adds nothing.
        let queued = try JSONDecoder().decode([QueuedInboxItem].self, from: Data("[]".utf8))
        XCTAssertTrue(queued.isEmpty)
        try await IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
            .deliver(QueuedInboxItem(id: try XCTUnwrap(server.addedByPhone.first?["id"] as? String), title: "Call Tom"))
        XCTAssertEqual(server.addedByPhone.count, 1)
    }

    func testAnItemTheMacRefusesStopsWaitingWithItsReason() async throws {
        let keys = MemoryAgentKeyStore()
        try keys.setKey("sk-x", for: .anthropic)
        let model = model(keys: keys)
        server.addRefusal = (400, "title is too long")
        let outcome = await model.inbox.add(title: "x")
        guard case .rejected(_, let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(reason, "title is too long")
    }

    func testAMacThatHasNoRouteKeepsTheItemWaiting() async throws {
        server.addRefusal = (404, "not found")
        let model = model()
        let outcome = await model.inbox.add(title: "Call Tom")
        guard case .queued = outcome else { return XCTFail("\(outcome)") }
        let waiting = await model.inbox.pending
        XCTAssertEqual(waiting.map(\.title), ["Call Tom"])
    }

    func testTheSettingsDefaultToAnthropicWithTheCurrentSonnet() {
        let settings = PhoneAgentSettings(defaults: defaults)
        XCTAssertEqual(settings.config.provider, .anthropic)
        XCTAssertEqual(settings.config.model, "claude-sonnet-5-5")
        settings.config = AgentConfig(provider: .openai, model: "gpt-x")
        XCTAssertEqual(PhoneAgentSettings(defaults: defaults).config, AgentConfig(provider: .openai, model: "gpt-x"))
    }

    func testWebPagesAreReducedToText() {
        XCTAssertEqual(URLSessionWebFetcher.plainText("<html><style>a{}</style><script>x()</script><body><h1>Hi</h1>\n<p>there</p></body></html>"), "Hi there")
    }
}
