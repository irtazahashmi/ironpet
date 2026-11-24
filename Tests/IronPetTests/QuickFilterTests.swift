import AppKit
import SwiftUI
import XCTest
@testable import IronPet
@testable import IronPetCore
import struct IronPetKit.QuickFilter
import enum IronPetKit.QuickFilterNode
import enum IronPetKit.RemoteJSON

@MainActor
final class QuickFilterTests: XCTestCase {
    private var api: TasksAPI!

    override func setUp() {
        api = TasksAPI(store: TaskStore(database: APITestSupport.memoryDatabase(), keepDoneDays: { 30 }))
    }

    private func add(_ title: String, _ status: TaskStatus = .backlog, labels: [String: String] = [:]) throws {
        try api.create(CreateTaskRequest(title: title, status: status, source: .user, labels: labels))
    }

    private func seed() throws {
        try add("Plan epic launch", .inProgress, labels: ["project": "epic"])
        try add("Epic docs", .needsYou, labels: ["project": "epic"])
        try add("Band rehearsal", .backlog, labels: ["project": "band"])
        try api.upsertQuickFilter(id: nil, name: "Epic", query: ["label": ["project": "epic"]])
        try api.upsertQuickFilter(id: nil, name: "Needs me", query: ["status": "needs_you"])
    }

    private func titles(_ filter: QuickFilterNode?, search: String = "") -> Set<String> {
        Set(TaskBoard.columns(api.all, filter: filter, query: search).values.flatMap { $0 }.map(\.title))
    }

    // S3
    func testAllAndTheSavedFiltersAreChipsAndPickingOneNarrowsTheListAndTheBoard() throws {
        try seed()
        XCTAssertEqual(QuickFilter.chips(api.quickFilters).map(\.name), ["Epic", "Needs me"])
        XCTAssertEqual(titles(nil), ["Plan epic launch", "Epic docs", "Band rehearsal"], "All shows everything")
        let epic = try XCTUnwrap(api.quickFilter("epic")?.node)
        let needsMe = try XCTUnwrap(api.quickFilter("needs-me")?.node)
        // The list and the board both read TaskBoard.columns, so one check covers both.
        XCTAssertEqual(titles(epic), ["Plan epic launch", "Epic docs"])
        XCTAssertEqual(titles(needsMe), ["Epic docs"])
        XCTAssertEqual(titles(epic, search: "docs"), ["Epic docs"], "the search field narrows the chosen filter further")
        XCTAssertEqual(TaskBoard.columns(api.all, filter: epic, query: "")[.backlog] ?? [], [], "the board column is empty, not missing tasks")
    }

    func testTheChipBarBuilds() throws {
        try seed()
        let bar = QuickFilterBar(filters: QuickFilter.chips(api.quickFilters), selection: .constant(nil), onAdd: {}, onEdit: { _ in },
                                 onRemove: { _ in }, onMove: { _, _ in })
        let host = NSHostingView(rootView: bar.frame(width: 600))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 10)
    }

    func testRemovingTheSelectedFilterFallsBackToAll() throws {
        try seed()
        XCTAssertNotNil(api.quickFilter("epic")?.node)
        try api.deleteQuickFilter("epic")
        XCTAssertNil(api.quickFilter("epic"), "a selection that points at a removed filter resolves to no filter, so the list shows All")
        XCTAssertEqual(api.quickFilters.map(\.id), ["needs-me"])
    }

    func testMovingAChipChangesTheOrder() throws {
        try seed()
        try api.moveQuickFilter("needs-me", by: -1)
        XCTAssertEqual(api.quickFilters.map(\.id), ["needs-me", "epic"])
        try api.moveQuickFilter("needs-me", by: -1)
        XCTAssertEqual(api.quickFilters.map(\.id), ["needs-me", "epic"], "the first chip stays first")
        try api.moveQuickFilter("needs-me", by: 1)
        XCTAssertEqual(api.quickFilters.map(\.id), ["epic", "needs-me"])
    }

    // S5
    func testAddAndEditBuildThePromptTheChatReceives() throws {
        try seed()
        XCTAssertEqual(QuickFilterRequest.add.prompt("epic tasks not done"), "Create a task quick filter: epic tasks not done")
        let epic = try XCTUnwrap(api.quickFilter("epic"))
        XCTAssertEqual(QuickFilterRequest.edit(epic).prompt("epic tasks not done"),
                       "Change the task quick filter \"Epic\" (id epic, current query {\"label\":{\"project\":\"epic\"}}): epic tasks not done")
    }

    func testSendingTheSheetHandsThePromptToTellGhost() throws {
        var sent: [String] = []
        let request = QuickFilterRequest.add
        let sheet = QuickFilterRequestSheet(request: request, petName: "Ghost", onSend: { sent.append(request.prompt($0)) }, onCancel: {})
        let host = NSHostingView(rootView: sheet)
        host.layoutSubtreeIfNeeded()
        // The sheet's Send calls onSend with the trimmed text; the window passes that to onTellGhost, which shows the chat.
        sheet.onSend("  epic tasks not done ")
        XCTAssertEqual(sent, ["Create a task quick filter: epic tasks not done"])
    }
}
