import XCTest
@testable import IronPetCore

/// The repeatable cleanup: it proposes, the user approves or skips each proposal, and nothing changes before approval.
@MainActor
final class MemoryCleanupTests: XCTestCase {
    private var store: EntityMemoryStore!

    override func setUp() async throws {
        store = EntityMemoryStore(database: try Database(path: nil, migrations: AppMigrations.all))
    }

    private func remember(_ text: String, _ scope: MemoryScope, _ entity: String) {
        _ = store.remember(text, scope: scope, entity: entity, source: "chat:a")
    }

    private func texts(_ id: String) -> [String] { store.claims(of: id).map(\.text) }

    private func classifier(_ places: [String: (MemoryScope, String)], merges: [MemoryCleanup.MergeSuggestion] = []) -> MemoryCleanup.Classifier {
        { batch, _ in
            MemoryCleanup.Answer(moves: batch.compactMap { note in places[note.text].map { MemoryResort.Classification(ref: note.ref, scope: $0.0, entity: $0.1) } },
                                 merges: merges)
        }
    }

    func testIronPetFactsOnTheBorkoPageAreProposedForTheIronPetPage() async throws {
        remember("Is a macOS desktop pet.", .project, "IronPet")
        remember("Ships every Friday.", .project, "borko")
        remember("IronPet stores memory in SQLite.", .project, "borko")
        let run = await MemoryCleanup.propose(in: store, classify: classifier(["IronPet stores memory in SQLite.": (.project, "IronPet")]))
        let move = try XCTUnwrap(run.proposals.first { $0.id.hasPrefix("move:") })
        XCTAssertEqual(move.title, "Move 1 note to IronPet")
        XCTAssertEqual(texts("project:borko").count, 2, "nothing moved before approval")
        XCTAssertEqual(try MemoryCleanup.apply(move, in: store).get(), "Moved 1 note to IronPet.")
        XCTAssertEqual(texts("project:borko"), ["Ships every Friday."])
        XCTAssertTrue(texts("project:ironpet").contains("IronPet stores memory in SQLite."))
    }

    func testAnOrganizationPageToCreateIsProposedAndMadeOnApproval() async throws {
        remember("Pays invoices late.", .project, "borko")
        let run = await MemoryCleanup.propose(in: store, classify: classifier(["Pays invoices late.": (.org, "Acme")]))
        let move = try XCTUnwrap(run.proposals.first)
        XCTAssertTrue(move.createsPage)
        XCTAssertNil(store.entities().first { $0.id == "org:acme" })
        _ = try MemoryCleanup.apply(move, in: store).get()
        XCTAssertEqual(texts("org:acme"), ["Pays invoices late."])
    }

    func testFivePagesForOneProductAreProposedAsOneMerge() async throws {
        let names = ["Self Service Portal", "Self-Service Portal", "self service portal", "Self Service Portal (SSP)", "SSP"]
        // Pages made before name variants found one page, so each has its own id.
        for (index, name) in names.enumerated() {
            _ = try store.importPage(id: "project:p\(index)", type: .project, name: name, identifiers: [], mentions: 1,
                                     notes: [MemoryNote(text: "Fact \(index).", date: "2026-10-0\(index + 1)", source: "chat:a")])
        }
        let run = await MemoryCleanup.propose(in: store, classify: nil)
        let merges = run.proposals.filter { $0.id.hasPrefix("merge:") }
        XCTAssertEqual(merges.count, 1)
        guard case .merge(let pages, _) = try XCTUnwrap(merges.first).action else { return XCTFail("not a merge") }
        XCTAssertEqual(pages.count, store.entities().filter { $0.type == .project }.count - 1)
    }

    func testTheModelCanSuggestAMergeTheChecksMiss() async throws {
        remember("Ships weekly.", .project, "Self Service Portal")
        remember("Runs on Postgres.", .project, "Customer Hub")
        let suggestion = MemoryCleanup.MergeSuggestion(keep: "Self Service Portal", others: ["Customer Hub"])
        let run = await MemoryCleanup.propose(in: store, classify: classifier([:], merges: [suggestion]))
        XCTAssertEqual(run.proposals.filter { $0.id.hasPrefix("merge:") }.count, 1)
    }

    func testASkippedProposalIsNotOfferedAgainButANewOneIs() async throws {
        remember("Pays invoices late.", .project, "borko")
        remember("Likes tea.", .project, "borko")
        let classify = classifier(["Pays invoices late.": (.org, "Acme")])
        let first = await MemoryCleanup.propose(in: store, classify: classify)
        MemoryCleanup.skip(try XCTUnwrap(first.proposals.first), in: store)
        let second = await MemoryCleanup.propose(in: store, classify: classify)
        XCTAssertTrue(second.proposals.isEmpty)
        let other = await MemoryCleanup.propose(in: store, classify: classifier(["Likes tea.": (.topic, "Tea")]))
        XCTAssertEqual(other.proposals.count, 1)
    }

    func testAnEmptyMisspeltPageIsProposedForMergeAndAnEmptyUnknownOneForDeletion() async throws {
        remember("Is a macOS desktop pet.", .project, "IronPet")
        _ = try store.importPage(id: "project:ironpt", type: .project, name: "IronPt", identifiers: [], mentions: 0, notes: [])
        _ = try store.importPage(id: "tool:zzqx", type: .tool, name: "Zzqx", identifiers: [], mentions: 0, notes: [])
        let run = await MemoryCleanup.propose(in: store, classify: nil)
        let misspelt = try XCTUnwrap(run.proposals.first { $0.id.contains("project:ironpt") })
        XCTAssertTrue(misspelt.id.hasPrefix("merge:"))
        XCTAssertEqual(run.proposals.first { $0.id == "delete:tool:zzqx" }?.title, "Delete the page Zzqx")
        _ = try MemoryCleanup.apply(try XCTUnwrap(run.proposals.first { $0.id == "delete:tool:zzqx" }), in: store).get()
        XCTAssertNil(store.entities().first { $0.id == "tool:zzqx" })
    }

    func testAWorkItemPageIsProposedForDeletionAndApprovalForgetsItsNotes() async throws {
        _ = try store.importPage(id: "project:ssp-10435", type: .project, name: "SSP-10435", identifiers: [], mentions: 1,
                                 notes: [MemoryNote(text: "Waiting for review.", date: "2026-10-01", source: "chat:a")])
        _ = try store.remember("Ships weekly.", scope: .project, entity: "Self Service Portal", source: "chat:a").get()
        let run = await MemoryCleanup.propose(in: store, classify: nil)
        let delete = try XCTUnwrap(run.proposals.first { $0.id.hasPrefix("delete:") })
        XCTAssertTrue(delete.detail.contains("ticket, issue or PR"))
        _ = try MemoryCleanup.apply(delete, in: store).get()
        XCTAssertTrue(store.browseRows().allSatisfy { $0.name != "SSP-10435" })
        XCTAssertFalse(store.history(of: "project:ssp-10435").isEmpty, "the notes stay in the history")
    }

    func testAnEmptyPageNothingRefersToIsNotAPersonStub() async throws {
        _ = try store.importPage(id: "person:ana", type: .person, name: "Ana", identifiers: [], mentions: 1, notes: [])
        let run = await MemoryCleanup.propose(in: store, classify: nil)
        XCTAssertTrue(run.proposals.isEmpty)
    }

    func testANoteFromAChatThatNamedNoProjectWaitsAndTheCleanupFilesIt() async throws {
        _ = store.park("Ships every Friday.", folder: "borko", source: "chat:a")
        XCTAssertNil(store.entities().first { $0.id.hasPrefix("project:") })
        XCTAssertEqual(store.unsorted().map(\.text), ["Ships every Friday."])
        let run = await MemoryCleanup.propose(in: store, classify: classifier(["Ships every Friday.": (.project, "IronPet")]))
        _ = try MemoryCleanup.apply(try XCTUnwrap(run.proposals.first), in: store).get()
        XCTAssertEqual(texts("project:ironpet"), ["Ships every Friday."])
        XCTAssertTrue(store.unsorted().isEmpty)
    }

    func testForgettingEverythingAlsoDropsTheWaitingNotes() {
        _ = store.park("Ships every Friday.", folder: "borko", source: "chat:a")
        store.forgetEverything()
        XCTAssertTrue(store.unsorted().isEmpty)
    }

    func testRunningTheCleanupAgainWithNothingLeftProposesNothing() async throws {
        remember("Pays invoices late.", .project, "borko")
        let classify = classifier(["Pays invoices late.": (.org, "Acme")])
        let first = await MemoryCleanup.propose(in: store, classify: classify)
        _ = try MemoryCleanup.apply(try XCTUnwrap(first.proposals.first), in: store).get()
        let second = await MemoryCleanup.propose(in: store, classify: classify)
        XCTAssertTrue(second.proposals.isEmpty)
    }

    func testAFailedModelStillGivesTheChecksAndSaysSo() async throws {
        _ = try store.importPage(id: "tool:zzqx", type: .tool, name: "Zzqx", identifiers: [], mentions: 0, notes: [])
        remember("A note.", .project, "borko")
        let run = await MemoryCleanup.propose(in: store) { _, _ in nil }
        XCTAssertTrue(run.modelFailed)
        XCTAssertEqual(run.proposals.map(\.id), ["delete:tool:zzqx"])
    }

    func testTheAnswerParses() {
        let answer = MemoryCleanup.parse(#"{"moves":[{"ref":"claim_a","scope":"org","entity":"Acme"}],"merges":[{"keep":"A","others":["B"]},{"keep":"C"}]}"#)
        XCTAssertEqual(answer?.moves.count, 1)
        XCTAssertEqual(answer?.merges, [.init(keep: "A", others: ["B"])])
        XCTAssertNil(MemoryCleanup.parse("not json"))
    }

    func testNearDuplicateNotesOnOnePageAreProposedAsOneMergePerGroup() async throws {
        // Written the way an older build did, which stored every rewording.
        let orcaTexts = [NearDuplicateTests.bloated] + NearDuplicateTests.restatements + [NearDuplicateTests.branches]
        for (index, text) in orcaTexts.enumerated() {
            _ = try store.importPage(id: "tool:orca", type: .tool, name: "Orca", identifiers: [], mentions: 1,
                                     notes: [MemoryNote(text: text, date: "2026-11-27", source: "chat:\(index)")])
        }
        for (index, text) in [NearDuplicateTests.jiraA, NearDuplicateTests.jiraB].enumerated() {
            _ = try store.importPage(id: "tool:jira", type: .tool, name: "Jira", identifiers: [], mentions: 1,
                                     notes: [MemoryNote(text: text, date: "2026-11-27", source: "chat:j\(index)")])
        }
        let run = await MemoryCleanup.propose(in: store, classify: nil)
        let merges = run.proposals.filter { $0.id.hasPrefix("notes:") }
        XCTAssertEqual(merges.count, 2)
        XCTAssertEqual(store.claims(of: "tool:orca").count, 5, "nothing changes before approval")
        let orca = try XCTUnwrap(merges.first { $0.id.hasPrefix("notes:tool:orca:") })
        _ = try MemoryCleanup.apply(orca, in: store).get()
        let left = store.claims(of: "tool:orca")
        XCTAssertEqual(left.count, 2, "the merged note and the different Orca fact")
        let merged = try XCTUnwrap(left.first { $0.text != NearDuplicateTests.branches })
        XCTAssertEqual(Set(merged.sources), ["chat:0", "chat:1", "chat:2", "chat:3"])
        let change = try XCTUnwrap(store.recentChanges().first)
        try store.undo(change).get()
        XCTAssertEqual(store.claims(of: "tool:orca").count, 5, "Undo brings the old notes back")
    }
}
