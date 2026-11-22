import XCTest
@testable import IronPet
@testable import IronPetCore

/// ChatSession, ACPBackend and DraftPolicy move into the core target, so they must not name Mac-only code.
@MainActor
final class ChatSessionCoreTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/IronPetCore")

    func testCoreChatFilesNameNoMacCode() throws {
        let files = ["Chat/ChatSession.swift", "Chat/ACP/ACPBackend.swift", "Chat/DraftPolicy.swift", "Chat/ChatLog.swift"]
        let banned = try NSRegularExpression(pattern: #"^\s*import (Combine|os|AppKit|AVFoundation)\b|@Published|\b(SpeechPlayer|ImageIntake|ScreenCapture|CaptureAXSource|MacFileIntake)\b"#)
        for file in files {
            let text = try String(contentsOf: Self.sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                XCTAssertNil(banned.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), "\(file): \(line)")
            }
        }
    }

    func testSpokenReplyGoesToTheSpeechOutput() async {
        let fake = FakeSpeechOutput()
        fake.isEnabled = { true }
        let session = ChatSession(restore: false, speech: fake)
        session.workspace = FileManager.default.temporaryDirectory
        var deliver: [(AgentEvent) -> Void] = []
        session.turnRunner = { _, onEvent in deliver.append(onEvent) }
        XCTAssertEqual(session.submitLocal("hi", files: [], reply: nil), .sent)
        for _ in 0..<10 { await Task.yield() }
        deliver[0](.assistant("Two files changed."))
        deliver[0](.finished(error: nil))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(fake.spoken.map(\.text), ["Two files changed."])
    }

    func testSpeechFailureShowsAsAnErrorItem() {
        let fake = FakeSpeechOutput()
        let session = ChatSession(restore: false, speech: fake)
        fake.onFailure?("server down")
        XCTAssertTrue(session.items.contains { if case .error("server down") = $0.kind { true } else { false } })
    }

    func testStreamedReplyNotifiesObserversOnEveryChangeInOrder() async {
        let session = ChatSession(restore: false)
        session.workspace = FileManager.default.temporaryDirectory
        var deliver: [(AgentEvent) -> Void] = []
        session.turnRunner = { _, onEvent in deliver.append(onEvent) }
        var states: [ChatSession.State] = []
        var sends = 0
        let token = session.changes.observe { sends += 1 }
        _ = session.submitLocal("go", files: [], reply: nil)
        for _ in 0..<10 { await Task.yield() }
        let afterSend = sends
        XCTAssertGreaterThan(afterSend, 0)
        let chunks = (0..<20).map { "chunk\($0) " }
        var expected = ""
        for (index, chunk) in chunks.enumerated() {
            if index == 10 { deliver[0](.toolStarted(id: "t1", summary: "Running tests")); deliver[0](.toolFinished(id: "t1", ok: true)) }
            let before = sends
            deliver[0](.assistant(chunk))
            expected += chunk
            XCTAssertGreaterThan(sends, before, "chunk \(index) did not notify")
        }
        states.append(session.state)
        deliver[0](.finished(error: nil))
        XCTAssertEqual(states, [.running])
        XCTAssertEqual(session.state, .done)
        let texts = session.items.compactMap { item -> String? in if case .assistant(let t) = item.kind { t } else { nil } }
        XCTAssertEqual(texts.joined(), expected)
        XCTAssertTrue(session.items.contains { if case .tool = $0.kind { true } else { false } })
        XCTAssertEqual(texts.count, 2, "the tool call splits the reply in place")
        withExtendedLifetime(token) {}
    }

    func testSignalFiresBeforeTheValueMoves() {
        let session = ChatSession(restore: false)
        var seen: [String?] = []
        let token = session.changes.observe { seen.append(session.agentMode) }
        session.receiveModes(current: "plan", modes: [AgentMode(id: "plan", name: "Plan")])
        XCTAssertEqual(seen.first, .some(nil), "willSet: the handler still sees the old value")
        withExtendedLifetime(token) {}
    }
}
