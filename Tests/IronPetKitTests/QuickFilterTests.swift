import XCTest
@testable import IronPetKit

final class QuickFilterTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 2026-11-23 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_795_435_200)

    private func day(_ text: String, _ hour: Int = 0) -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
    }

    private func task(_ id: String, _ status: TaskStatus = .backlog, source: String = "user", due: Date? = nil, waitingOn: String? = nil,
                      labels: [String: String] = [:], title: String? = nil, notes: String = "") -> RemoteTask {
        RemoteTask(id: id, title: title ?? id, notes: notes, status: status, source: source, due: due, waitingOn: waitingOn, labels: labels)
    }

    private func ids(_ query: String, in tasks: [RemoteTask]) throws -> Set<String> {
        let json = try JSONSerialization.jsonObject(with: Data(query.utf8))
        let node = try QuickFilterNode.parse(json)
        return Set(tasks.filter { node.matches($0, now: now, calendar: calendar) }.map(\.id))
    }

    private lazy var sample: [RemoteTask] = [
        task("epic-open", .inProgress, source: "chat", due: day("2026-11-20"), labels: ["project": "epic", "merge": "auto"]),
        task("epic-done", .done, source: "chat", labels: ["project": "epic"]),
        task("band-open", .needsYou, source: "meeting", due: day("2026-12-05"), labels: ["project": "band"]),
        task("held", .backlog, source: "meeting", waitingOn: "Ana", notes: "Waiting for the INVOICE"),
        task("plain", .backlog, labels: [:], title: "Pay the Invoice"),
        task("later-today", .backlog, due: day("2026-11-23", 18)),
        task("earlier-today", .backlog, due: day("2026-11-23", 9)),
        task("today-allday", .backlog, due: day("2026-11-23")),
    ]

    // S1
    func testLabelsAndStatusesCombineWithAndOrNot() throws {
        XCTAssertEqual(try ids(#"{"label":{"project":"epic"}}"#, in: sample), ["epic-open", "epic-done"])
        XCTAssertEqual(try ids(#"{"labelExists":"merge"}"#, in: sample), ["epic-open"])
        XCTAssertEqual(try ids(#"{"and":[{"label":{"project":"epic"}},{"not":{"status":"done"}}]}"#, in: sample), ["epic-open"])
        XCTAssertEqual(try ids(#"{"or":[{"label":{"project":"band"}},{"status":"done"}]}"#, in: sample), ["band-open", "epic-done"])
        XCTAssertEqual(try ids(#"{"status":["needs_you","in_progress"]}"#, in: sample), ["epic-open", "band-open"])
        XCTAssertEqual(try ids(#"{"not":{"or":[{"labelExists":"project"},{"status":"backlog"}]}}"#, in: sample), [])
    }

    func testWaitingOnSourceAndText() throws {
        XCTAssertEqual(try ids(#"{"waitingOn":"ana"}"#, in: sample), ["held"], "the name matches without regard to case")
        XCTAssertFalse(try ids(#"{"waitingOn":null}"#, in: sample).contains("held"))
        XCTAssertEqual(try ids(#"{"and":[{"waitingOn":null},{"source":"meeting"}]}"#, in: sample), ["band-open"])
        XCTAssertEqual(try ids(#"{"source":["chat","meeting"]}"#, in: sample), ["epic-open", "epic-done", "band-open", "held"])
        XCTAssertEqual(try ids(#"{"text":"invoice"}"#, in: sample), ["held", "plain"], "title and notes, any case")
    }

    func testDueConditions() throws {
        XCTAssertEqual(try ids(#"{"due":{"before":"2026-11-23"}}"#, in: sample), ["epic-open"])
        XCTAssertEqual(try ids(#"{"due":{"after":"2026-11-23"}}"#, in: sample), ["band-open"])
        XCTAssertEqual(try ids(#"{"due":"none"}"#, in: sample), ["epic-done", "held", "plain"])
        // At noon: yesterday's plain date and the 09:00 time are overdue, the all-day date today and the 18:00 time are not.
        XCTAssertEqual(try ids(#"{"due":"overdue"}"#, in: sample), ["epic-open", "earlier-today"])
        XCTAssertFalse(try ids(#"{"due":"overdue"}"#, in: [task("old", .done, due: day("2026-01-01"))]).contains("old"), "done tasks are never overdue")
    }

    // S2 (the part that is the same on the phone)
    func testABadQueryNamesTheNode() {
        func message(_ query: String) -> String {
            do { _ = try QuickFilterNode.parse(try JSONSerialization.jsonObject(with: Data(query.utf8))); return "parsed" }
            catch let error as QuickFilterError { return error.description } catch { return "\(error)" }
        }
        XCTAssertTrue(message(#"{"color":"red"}"#).hasPrefix("query: unknown condition \"color\""))
        XCTAssertTrue(message(#"{"and":[{"status":"done"},{"status":"finished"}]}"#).hasPrefix("query.and[1].status: \"finished\" is not a status"))
        XCTAssertTrue(message(#"{"and":[]}"#).hasPrefix("query.and: must be a non-empty array"))
        XCTAssertTrue(message(#"{"or":[]}"#).hasPrefix("query.or: must be a non-empty array"))
        XCTAssertTrue(message(#"{"not":{"labelExists":3}}"#).hasPrefix("query.not.labelExists:"))
        XCTAssertTrue(message(#"{"due":{"before":"2026-13-40"}}"#).hasPrefix("query.due.before: must be a date"))
        XCTAssertTrue(message(#"{"status":"done","text":"x"}"#).contains("has 2 keys"))
        XCTAssertTrue(message(#"["status"]"#).hasPrefix("query: must be an object"))
        XCTAssertEqual(message(#"{"text":"ok"}"#), "parsed")
    }

    func testDeepOrHugeQueriesAreRefused() throws {
        var nested = #"{"text":"x"}"#
        for _ in 0..<QuickFilterNode.maxDepth { nested = #"{"not":"# + nested + "}" }
        XCTAssertThrowsError(try QuickFilterNode.parse(try JSONSerialization.jsonObject(with: Data(nested.utf8))))
        let wide = #"{"or":["# + Array(repeating: #"{"text":"x"}"#, count: QuickFilterNode.maxNodes + 1).joined(separator: ",") + "]}"
        XCTAssertThrowsError(try QuickFilterNode.parse(try JSONSerialization.jsonObject(with: Data(wide.utf8))))
    }

    func testChipsKeepTheirOrderAndHideWhatThisBuildCannotRead() throws {
        let known = RemoteJSON.object(["text": .string("x")])
        let filters = [QuickFilter(id: "b", name: "B", query: known, order: 1),
                       QuickFilter(id: "newer", name: "Newer", query: .object(["future": .bool(true)]), order: 0),
                       QuickFilter(id: "a", name: "A", query: known, order: 0)]
        XCTAssertEqual(QuickFilter.chips(filters).map(\.id), ["a", "b"])
        XCTAssertFalse(filters[1].matches(task("t")), "an unreadable filter matches nothing")
    }

    func testAFilterSurvivesAJSONRoundTrip() throws {
        let source = QuickFilter(id: "epic", name: "Epic", query: RemoteJSON(foundation: try JSONSerialization.jsonObject(
            with: Data(#"{"and":[{"label":{"project":"epic"}},{"not":{"status":"done"}}]}"#.utf8)))!, order: 2)
        let data = try JSONEncoder().encode(source)
        XCTAssertEqual(try JSONDecoder().decode(QuickFilter.self, from: data), source)
        XCTAssertEqual(source.queryText, #"{"and":[{"label":{"project":"epic"}},{"not":{"status":"done"}}]}"#)
    }

    // S5 (the text both apps send)
    func testPromptsCarryTheTextAndForAnEditTheIdAndQuery() {
        XCTAssertEqual(QuickFilterPrompt.add(" epic tasks not done "), "Create a task quick filter: epic tasks not done")
        let filter = QuickFilter(id: "epic-open", name: "Epic, open", query: .object(["text": .string("epic")]))
        XCTAssertEqual(QuickFilterPrompt.edit(filter, "epic tasks not done"),
                       #"Change the task quick filter "Epic, open" (id epic-open, current query {"text":"epic"}): epic tasks not done"#)
    }
}
