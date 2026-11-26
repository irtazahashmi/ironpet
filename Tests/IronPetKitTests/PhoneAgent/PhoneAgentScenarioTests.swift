import XCTest
@testable import IronPetKit

/// The scenarios of the phone agent that need no device: the loop, the inbox queue and the tools together.
final class PhoneAgentScenarioTests: XCTestCase {
    private func agent(_ mac: FakeMac, store: MemoryInboxQueueStore = MemoryInboxQueueStore(), transport: ScriptedTransport) -> (AgentLoop, PhoneInbox) {
        let inbox = PhoneInbox(store: store, remote: mac)
        let tools: [any AgentTool] = InboxTools.all(inbox) + [DateTimeTool(), PhoneAgentSkills.LoadTool(PhoneAgentSkills.bundled)]
        return (AgentLoop(transport: transport, keys: FixedKey(key: "sk"), tools: tools, system: PhoneAgentPrompt.system(skills: PhoneAgentSkills.bundled)), inbox)
    }

    // MARK: S1

    func testAReminderIsQueuedOnThePhoneWhileTheMacIsOutOfReachAndSentWhenItAnswers() async throws {
        let mac = FakeMac()
        let transport = ScriptedTransport([
            AgentFixtures.anthropicToolCall(arguments: ["{\"title\":\"Call Tom\",\"due\":\"2026-11-27\"}"]),
            AgentFixtures.anthropicText,
        ])
        let (loop, inbox) = agent(mac, transport: transport)
        let turns = try await loop.run("remind me to call Tom tomorrow", history: [], config: AgentConfig())

        let pending = await inbox.pending
        XCTAssertEqual(pending.map(\.title), ["Call Tom"], "the item waits on the phone")
        XCTAssertEqual(pending.first?.due, "2026-11-27")
        XCTAssertTrue(mac.delivered.isEmpty)
        guard case .toolResults(let results) = turns[2] else { return XCTFail() }
        XCTAssertTrue(results[0].text.contains("goes to the inbox when the Mac answers"), results[0].text)
        XCTAssertFalse(results[0].isError)

        mac.setReachable(true)
        let taken = await inbox.flush()
        XCTAssertEqual(taken, 1)
        XCTAssertEqual(mac.delivered.map(\.title), ["Call Tom"], "the Mac has the item once it is reachable")
        let left = await inbox.pending
        XCTAssertTrue(left.isEmpty)
    }

    func testAQueuedItemSurvivesARestartAndKeepsItsStableId() async throws {
        let mac = FakeMac()
        let store = MemoryInboxQueueStore()
        let first = PhoneInbox(store: store, remote: mac)
        _ = await first.add(title: "Call Tom")
        let queued = await first.pending
        let id = try XCTUnwrap(queued.first?.id)
        XCTAssertTrue(id.hasPrefix("phone-"))

        let second = PhoneInbox(store: store, remote: mac)
        let reloaded = await second.pending
        XCTAssertEqual(reloaded.map(\.id), [id])
        mac.setReachable(true)
        _ = await second.flush()
        XCTAssertEqual(mac.delivered.map(\.id), [id], "the Mac saw the id the phone made")
    }

    func testSendingTheSameItemTwiceAddsItOnce() async throws {
        let mac = FakeMac()
        mac.setReachable(true)
        let item = QueuedInboxItem(title: "Call Tom")
        try await mac.deliver(item)
        try await mac.deliver(item)
        XCTAssertEqual(mac.delivered.count, 1)
    }

    func testItemsAreSentInOrderAndStopAtTheFirstOneTheMacCannotTake() async throws {
        let mac = FakeMac()
        let inbox = PhoneInbox(store: MemoryInboxQueueStore(), remote: mac)
        _ = await inbox.add(title: "one")
        _ = await inbox.add(title: "two")
        XCTAssertEqual(mac.attempts, 2, "the first add tried one, the second add tried one again and stopped there")
        let pending = await inbox.pending
        XCTAssertEqual(pending.map(\.title), ["one", "two"])
    }

    func testAnItemTheMacRefusesStopsWaitingAndKeepsTheReason() async throws {
        let mac = FakeMac()
        mac.setReachable(true)
        mac.refuse = "title is too long"
        let inbox = PhoneInbox(store: MemoryInboxQueueStore(), remote: mac)
        let outcome = await inbox.add(title: "x")
        guard case .rejected(_, let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(reason, "title is too long")
        mac.refuse = nil
        let resent = await inbox.flush()
        XCTAssertEqual(resent, 0, "a refused item is not sent again")
    }

    func testInboxListNamesWaitingItemsWhenTheMacIsOutOfReach() async throws {
        let mac = FakeMac()
        let inbox = PhoneInbox(store: MemoryInboxQueueStore(), remote: mac)
        _ = await inbox.add(title: "Call Tom")
        let text = try await InboxTools.all(inbox)[0].run([:])
        XCTAssertTrue(text.contains("not reachable"))
        XCTAssertTrue(text.contains("waiting on this phone: Call Tom"))
    }

    // MARK: S2

    func testACodingRequestGetsAnAnswerThatNeedsTheMacAndSendsNothing() async throws {
        let mac = FakeMac()
        mac.setReachable(true)
        let transport = ScriptedTransport([AgentFixtures.anthropicText])
        let (loop, inbox) = agent(mac, transport: transport)
        let turns = try await loop.run("fix the failing test in the ironpet repo", history: [], config: AgentConfig())

        guard case .assistant(let text, let calls) = try XCTUnwrap(turns.last) else { return XCTFail() }
        XCTAssertTrue(text.contains("needs the Mac"))
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(transport.requests.count, 1, "no further request")
        XCTAssertEqual(mac.attempts, 0, "nothing went to the Mac")
        XCTAssertTrue(mac.delivered.isEmpty)
        let pending = await inbox.pending
        XCTAssertTrue(pending.isEmpty)
    }

    func testThePhoneAgentHasNoToolThatSendsToAnotherAgentAndTheInstructionsSendMacWorkToTheMac() throws {
        let inbox = PhoneInbox(store: MemoryInboxQueueStore(), remote: FakeMac())
        let tools = InboxTools.all(inbox) + MemoryTools.all(StubMemory()) + [DateTimeTool(), WebFetchTool(StubFetcher()), PhoneAgentSkills.LoadTool([])]
            + CalendarTools.all(StubCalendar())
        let names = Set(tools.map(\.name))
        XCTAssertEqual(names, ["inbox_list", "inbox_add", "inbox_done", "inbox_remove", "memory_search", "memory_read", "current_datetime", "web_fetch",
                               "load_skill", "calendar_events", "reminder_add"])
        let system = PhoneAgentPrompt.system(skills: PhoneAgentSkills.bundled)
        XCTAssertTrue(system.contains("Coding, repositories, the Mac's screen and desktop apps need the Mac"))
        XCTAssertTrue(system.contains("capture-to-inbox"))
    }

    // MARK: Tools

    func testLoadSkillReturnsTheInstructionsAndAnUnknownNameIsAnError() async throws {
        let tool = PhoneAgentSkills.LoadTool(PhoneAgentSkills.bundled)
        let text = try await tool.run(["name": "capture-to-inbox"])
        XCTAssertTrue(text.contains("inbox_add"))
        do { _ = try await tool.run(["name": "nope"]); XCTFail() } catch let error as AgentError { XCTAssertTrue(error.message.contains("capture-to-inbox")) }
    }

    func testTheDateTimeToolNamesTheWeekdayInTheZone() async throws {
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let text = try await DateTimeTool(now: { date }, timeZone: zone).run([:])
        XCTAssertEqual(text, DateTimeTool.describe(date, in: zone))
        XCTAssertTrue(text.hasSuffix("time zone Europe/Berlin"))
        XCTAssertTrue(text.contains("("))
    }

    func testWebFetchRefusesLocalAndPrivateAddresses() {
        for bad in ["http://localhost/x", "http://127.0.0.1/", "http://192.168.1.1/", "http://10.0.0.5/", "http://172.20.0.1/", "http://printer.local/",
                    "http://my-mac/", "file:///etc/passwd", "ftp://example.com/", "http://[::1]/", "http://169.254.1.1/"] {
            XCTAssertFalse(WebFetchTool.allows(URL(string: bad)!), bad)
        }
        for good in ["https://example.com/a", "http://8.8.8.8/", "https://news.ycombinator.com"] { XCTAssertTrue(WebFetchTool.allows(URL(string: good)!), good) }
    }

    func testWebFetchCutsLongPages() async throws {
        let tool = WebFetchTool(StubFetcher(text: String(repeating: "a", count: 20_000)))
        let text = try await tool.run(["url": "https://example.com"])
        XCTAssertTrue(text.hasSuffix("[cut after 12000 characters]"))
    }

    func testCalendarToolsPassTheRefusalOfThePermissionPromptBack() async throws {
        let tools = CalendarTools.all(StubCalendar(error: AgentError("Calendar access is off. Turn it on in Settings.")))
        do { _ = try await tools[0].run(["days": "2"]); XCTFail() } catch let error as AgentError { XCTAssertTrue(error.message.contains("Calendar access")) }
    }

    func testThePhoneAgentFilesStayFoundationOnly() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/IronPetKit/PhoneAgent")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 5)
        for file in files {
            let imports = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("import ") }
            XCTAssertTrue(imports.allSatisfy { $0 == "import Foundation" }, "\(file.lastPathComponent) imports \(imports)")
        }
    }
}

private struct StubMemory: PhoneMemoryHost {
    func search(_ query: String) async throws -> String { "" }
    func page(_ id: String) async throws -> String { "" }
}

private struct StubFetcher: WebFetching {
    var text = "page"
    func fetch(_ url: URL) async throws -> String { text }
}

private struct StubCalendar: DeviceCalendarHost {
    var error: Error?
    func events(from start: Date, to end: Date) async throws -> [CalendarEntry] { if let error { throw error }; return [] }
    func addReminder(title: String, due: Date?) async throws { if let error { throw error } }
}
