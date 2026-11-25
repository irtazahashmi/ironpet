import XCTest
import IronPetKit
@testable import IronPetRemote

/// S1 and S2 of the send-latency fix: an option shows on the next frame, Submit is pending at once, and a refusal rolls both back.
@MainActor
final class FormLatencyTests: XCTestCase {
    var server: MockIronPetServer!
    private let form = RemoteForm(id: "f-1", message: "Which color?", fields: [
        RemoteFormField(id: "color", title: "Color", required: true, type: "single",
                        options: [RemoteFormOption(value: "red", title: "Red"), RemoteFormOption(value: "blue", title: "Blue")])
    ], canSubmit: true)

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func started() async -> ChatModel {
        var chat = server.chat
        chat.forms = [form]
        server.chat = chat
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        let model = ChatModel(client: client, events: events, onUnauthorized: {})
        model.start()
        await poll { model.loaded && model.forms.count == 1 }
        return model
    }

    private func poll(_ timeout: Double = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testAnOptionShowsOnTheNextFrameWhileTheMacTakesTwoSeconds() async {
        let model = await started()
        server.formDelay = 2.0
        var hops: [(String, ContinuousClock.Instant)] = []
        PhoneHopLog.tap = { hops.append(($0, .now)) }
        defer { PhoneHopLog.tap = nil }
        let start = ContinuousClock.now
        let answering = Task { await model.answer(model.forms[0], field: "color", .text("blue")) }
        await poll(1) { self.picked("blue", in: model) }
        let shown = ContinuousClock.now - start
        XCTAssertTrue(picked("blue", in: model))
        XCTAssertLessThan(shown, .milliseconds(500), "the choice draws before any network answer")
        await answering.value
        XCTAssertTrue(picked("blue", in: model), "the Mac's copy keeps the choice")
        let table = hops.map { hop -> String in
            let parts = (hop.1 - start).components
            return "\(hop.0) +\(Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)) ms"
        }
        print("form-latency hops: \(table.joined(separator: ", "))")
        model.stop()
    }

    func testSubmitIsPendingAtOnceAndEndsWhenTheMacAnswers() async {
        let model = await started()
        server.formDelay = 1.0
        let start = ContinuousClock.now
        let submitting = Task { await model.submit(model.forms[0]) }
        await poll(1) { model.submittingForms.contains("f-1") }
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(500))
        XCTAssertTrue(model.submittingForms.contains("f-1"))
        // The first request has reached the Mac before the second tap, so a count of one afterwards can only mean the tap sent nothing.
        await poll { self.server.count("POST /v1/chat/forms/f-1/submit") >= 1 }
        await model.submit(model.forms[0])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(server.count("POST /v1/chat/forms/f-1/submit"), 1, "a second tap sends nothing")
        await submitting.value
        XCTAssertTrue(model.submittingForms.isEmpty)
        await poll { model.forms.isEmpty }
        XCTAssertTrue(model.forms.isEmpty)
        model.stop()
    }

    func testARefusedAnswerRollsBackWithTheMacsReason() async {
        let model = await started()
        server.formFails = true
        await model.answer(model.forms[0], field: "color", .text("red"))
        XCTAssertFalse(picked("red", in: model), "the choice goes back")
        XCTAssertEqual(model.errorMessage, "That question already closed on the Mac.")
        model.stop()
    }

    func testARefusedSubmitEndsPendingAndKeepsTheForm() async {
        let model = await started()
        server.formFails = true
        await model.submit(model.forms[0])
        XCTAssertTrue(model.submittingForms.isEmpty)
        XCTAssertEqual(model.forms.count, 1)
        XCTAssertNotNil(model.errorMessage)
        model.stop()
    }

    private func picked(_ value: String, in model: ChatModel) -> Bool { model.forms.first?.answers["color"] == .text(value) }
}
