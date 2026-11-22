import XCTest
@testable import IronPet
@testable import IronPetCore

@MainActor
final class ChatResetTests: XCTestCase {
    private var session: ChatSession!
    private var h: ChatHarness!
    private var deliver: [(AgentEvent) -> Void] = []
    private var log: [String] = []
    private var turns: [ACPTurn] = []
    private let folder = FileManager.default.temporaryDirectory

    override func setUp() async throws {
        TestMemory.isolate()
        h = ChatHarness(); session = h.session
        deliver = []
        turns = []
        log = []
        ChatLog.sink = { [unowned self] in log.append($0) }
        session.workspace = folder
        session.turnRunner = { [unowned self] turn, onEvent in
            turns.append(turn)
            deliver.append(onEvent)
        }
    }

    override func tearDown() async throws { ChatLog.sink = nil }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    private func chatted(thread: String = "s1") async {
        h.model.input = "hello"
        await h.model.sendNow()
        await settle()
        deliver[0](.session(thread))
        deliver[0](.assistant("hi"))
        deliver[0](.finished(error: nil))
        await settle()
    }

    private func thread(id: String = "t2") -> ChatThread {
        ChatThread(id: id, title: "Old", workspace: "/tmp", updatedAt: Date(),
                   items: [.init(kind: .user("old"))], agent: session.agent.id)
    }

    func testS1PickedModeSurvivesNewChatAndRelaunch() async {
        let defaults = UserDefaults.standard
        let keys = ["chatThread", "chatDraft", "chatAttachments", "chatMode.cursor", "chatMode.claude-acp"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        defaults.removeObject(forKey: "chatThread")
        let first = ChatSession(restore: true)
        let key = "chatMode.\(first.agent.id)"
        defaults.removeObject(forKey: key)
        first.receiveModes(current: "default", modes: [AgentMode(id: "default", name: "Default"), AgentMode(id: "plan", name: "Plan")])
        first.setMode("plan")
        first.newChat()
        XCTAssertEqual(defaults.string(forKey: key), "plan", "a new chat must not overwrite the saved pick")
        let relaunched = ChatSession(restore: true)
        XCTAssertEqual(relaunched.pickedMode, "plan")
        defaults.removeObject(forKey: key)
        XCTAssertNil(ChatSession(restore: true).pickedMode, "without a pick the agent's own default applies")
    }

    func testS2OpenThreadKeepsThePickedMode() async {
        let key = "chatMode.\(session.agent.id)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set("plan", forKey: key)
        session.open(thread())
        XCTAssertEqual(session.threadID, "t2")
        XCTAssertEqual(session.pickedMode, "plan")
    }

    func testS3FailedTurnKeepsTranscriptAndThread() async {
        await chatted()
        let before = session.items.map(\.id)
        h.model.input = "again"
        await h.model.sendNow()
        await settle()
        deliver[1](.finished(error: "The agent stopped"))
        await settle()
        XCTAssertEqual(session.threadID, "s1")
        XCTAssertEqual(Array(session.items.map(\.id).prefix(before.count)), before)
    }

    func testS3LoadFallbackKeepsThread() async {
        await chatted()
        h.model.input = "again"
        await h.model.sendNow()
        await settle()
        // The agent could not load s1 and made a new session.
        deliver[1](.session("fresh"))
        deliver[1](.finished(error: nil))
        await settle()
        XCTAssertEqual(session.threadID, "s1")
        XCTAssertGreaterThanOrEqual(session.items.count, 3)
        XCTAssertTrue(log.contains { $0.contains("fresh") && $0.contains("kept") })
        h.model.input = "third"
        await h.model.sendNow()
        await settle()
        XCTAssertEqual(turns.last?.resume, "s1", "the next message continues in the same thread")
    }

    func testS4TelegramWhileBusyQueuesWithoutClearing() async {
        await chatted()
        h.model.input = "busy"
        await h.model.sendNow()
        await settle()
        let count = session.items.count
        session.submit("from phone", from: .telegram(chat: 7))
        XCTAssertEqual(session.userQueueCount, 1)
        XCTAssertEqual(session.items.count, count)
        XCTAssertEqual(session.threadID, "s1")
        session.cancel(from: .telegram(chat: 7))
        XCTAssertEqual(session.userQueueCount, 0)
        XCTAssertEqual(session.items.count, count)
        XCTAssertFalse(log.contains { $0.hasPrefix("chat cleared") })
    }

    func testShowingTheWindowKeepsTheChat() async {
        await chatted()
        session.prepareForShow()
        XCTAssertFalse(session.items.isEmpty)
        XCTAssertEqual(session.threadID, "s1")
        XCTAssertFalse(log.contains { $0.hasPrefix("chat cleared") })
    }

    func testS5EachChangeLogsItsReason() async {
        await chatted()
        session.newChat(reason: "menu")
        XCTAssertEqual(log.filter { $0.hasPrefix("chat cleared") }.count, 1)
        XCTAssertTrue(log.last?.contains("menu") == true)
        log = []
        session.open(thread())
        XCTAssertEqual(log.filter { $0.hasPrefix("thread t2 loaded") }.count, 1)
        log = []
        session.use(URL(fileURLWithPath: "/tmp/elsewhere"))
        XCTAssertEqual(log.filter { $0.hasPrefix("workspace changed") }.count, 1)
        log = []
        if let other = AgentCatalog.all.first(where: { $0 != session.agent }) {
            session.setAgent(other)
            XCTAssertTrue(log.contains { $0.hasPrefix("agent changed") })
        }
    }
}
