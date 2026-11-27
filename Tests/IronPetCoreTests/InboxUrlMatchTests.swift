import XCTest
@testable import IronPetCore

@MainActor
final class InboxUrlMatchTests: XCTestCase {
    private var store: TaskStore!

    override func setUp() async throws {
        try await super.setUp()
        store = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database)
    }

    private func add(_ key: String, _ url: String, title: String? = nil, due: String? = nil, notes: String = "") -> SuggestFiling? {
        store.file(.init(key: key, title: title ?? "Item \(key)", due: due, notes: notes, url: URL(string: url)), agent: .email, sourceRef: "mail:\(key)").first
    }

    func testGmailMessagesWithDifferentFragmentsStaySeparate() {
        _ = add("a", "https://mail.google.com/mail/u/0/#inbox/aaa")
        let second = add("b", "https://mail.google.com/mail/u/0/#inbox/bbb")
        XCTAssertEqual(second?.change, .added)
        XCTAssertEqual(store.suggestions.count, 2)
    }

    func testGitHubCommentsWithDifferentFragmentsStaySeparate() {
        XCTAssertNotEqual(InboxSource.normalized(URL(string: "https://github.com/o/r/pull/1#issuecomment-1")!),
                          InboxSource.normalized(URL(string: "https://github.com/o/r/pull/1#issuecomment-2")!))
        _ = add("a", "https://github.com/o/r/pull/1#issuecomment-1")
        XCTAssertEqual(add("b", "https://github.com/o/r/pull/1#issuecomment-2")?.change, .added)
    }

    func testSlashAndCaseStillMerge() {
        XCTAssertEqual(InboxSource.normalized(URL(string: "https://example.com/page/")!), InboxSource.normalized(URL(string: "https://example.com/page")!))
        XCTAssertEqual(InboxSource.normalized(URL(string: "HTTPS://Example.com/page")!), InboxSource.normalized(URL(string: "https://example.com/page")!))
        XCTAssertEqual(InboxSource.normalized(URL(string: "https://example.com/page#")!), InboxSource.normalized(URL(string: "https://example.com/page")!))
        _ = add("a", "https://example.com/page")
        XCTAssertEqual(add("b", "https://example.com/page/")?.change, .merged)
        XCTAssertEqual(add("c", "HTTPS://Example.com/page")?.change, .merged)
        XCTAssertEqual(store.suggestions.count, 1)
    }

    func testAMergeKeepsDueTitleAndNotes() throws {
        _ = add("a", "https://example.com/page", title: "First", due: "2026-12-01", notes: "old notes")
        _ = add("b", "https://example.com/page/", title: "Second", due: "2026-12-24", notes: "new notes")
        let item = try XCTUnwrap(store.suggestions.first)
        XCTAssertEqual(item.title, "First")
        XCTAssertEqual(item.due, "2026-12-01")
        XCTAssertEqual(item.notes, "old notes")
    }

    func testAPageAnchorIsDroppedButAnIdentifyingFragmentIsKept() {
        XCTAssertEqual(InboxSource.normalized(URL(string: "https://github.com/a/b/pull/1/#files")!), InboxSource.normalized(URL(string: "https://github.com/a/b/pull/1")!))
        XCTAssertNotEqual(InboxSource.normalized(URL(string: "https://mail.google.com/mail/u/0/#search/invoice")!),
                          InboxSource.normalized(URL(string: "https://mail.google.com/mail/u/0/#search/receipt")!))
    }
}
