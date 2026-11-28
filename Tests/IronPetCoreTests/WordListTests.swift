import XCTest
@testable import IronPetCore

@MainActor
final class WordListTests: XCTestCase {
    private var dir: URL!
    private var fileURL: URL { dir.appendingPathComponent("word-list.json") }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-words-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func vocabulary(entities: [String] = [], list: WordListStore? = nil) -> VoiceVocabulary {
        VoiceVocabulary(wordList: list ?? WordListStore(url: fileURL), entityNames: { entities })
    }

    // S1
    func testMisheardFormIsCorrected() async {
        let words = vocabulary()
        words.wordList.add("Langfuse", misheard: ["length fuse"])
        let text = await words.correct("check the prompts in length fuse")
        XCTAssertEqual(text, "check the prompts in Langfuse")
    }

    func testMisheardFormKeepsPunctuationAndCase() async {
        let words = vocabulary()
        words.wordList.add("Langfuse", misheard: ["length fuse"])
        let text = await words.correct("Open Length Fuse, then stop.")
        XCTAssertEqual(text, "Open Langfuse, then stop.")
    }

    // S2
    func testMemoryNameCountsWithoutBeingInTheList() async {
        let words = vocabulary(entities: ["IronPet"])
        XCTAssertTrue(words.wordList.terms.isEmpty)
        let text = await words.correct("open iron pet settings")
        XCTAssertEqual(text, "open IronPet settings")
    }

    func testMemoryNamesComeFromARealStore() async throws {
        let store = EntityMemoryStore(database: try Database(path: nil, migrations: AppMigrations.all))
        let project = ProjectKey(key: "github.com/you/ironpet", name: "IronPet", isRepo: true, workspace: URL(fileURLWithPath: "/Users/you/code/ironpet"))
        _ = try store.remember("A desktop pet", scope: .project, project: project, source: "chat:a").get()
        let words = VoiceVocabulary(wordList: WordListStore(url: fileURL), entityNames: { store.entities().map(\.name) })
        let text = await words.correct("open iron pet settings")
        XCTAssertEqual(text, "open IronPet settings")
    }

    // S3
    func testRemovedTermNoLongerCorrects() async {
        let words = vocabulary()
        words.wordList.add("Langfuse", misheard: ["length fuse"])
        let before = await words.correct("check length fuse")
        XCTAssertEqual(before, "check Langfuse")
        words.wordList.remove(id: "langfuse")
        let after = await words.correct("check length fuse")
        XCTAssertEqual(after, "check length fuse")
    }

    func testRemovalPersistsAcrossReload() {
        let list = WordListStore(url: fileURL)
        list.add("Langfuse", misheard: ["length fuse"])
        list.add("Kubernetes")
        XCTAssertEqual(WordListStore(url: fileURL).terms.map(\.term), ["Langfuse", "Kubernetes"])
        list.remove(id: "langfuse")
        XCTAssertEqual(WordListStore(url: fileURL).terms.map(\.term), ["Kubernetes"])
    }

    func testMemoryStillCorrectsAfterListRemoval() async {
        let words = vocabulary(entities: ["IronPet"])
        words.wordList.add("IronPet")
        words.wordList.remove(id: "ironpet")
        let text = await words.correct("open iron pet")
        XCTAssertEqual(text, "open IronPet")
    }

    func testEditChangesSpellingAndForms() {
        let list = WordListStore(url: fileURL)
        list.add("Langfuse", misheard: ["length fuse"])
        XCTAssertTrue(list.update(id: "langfuse", term: "LangFuse", misheard: ["lang few", "length fuse"]))
        XCTAssertEqual(WordListStore(url: fileURL).terms, [WordTerm(term: "LangFuse", misheard: ["lang few", "length fuse"])])
        list.add("Other")
        XCTAssertFalse(list.update(id: "other", term: "langfuse", misheard: []))
    }

    // S4
    func testOrdinarySentencesAreUnchanged() async {
        let words = vocabulary(entities: ["Alexander", "Michelle", "Kubernetes"])
        for term in ["Langfuse", "Postgres", "Terraform", "Grafana", "Prometheus", "Anthropic", "Sentry"] {
            words.wordList.add(term, misheard: ["\(term.lowercased()) x"])
        }
        let sentences = [
            "I will pick up the kids at five",
            "Can you check the weather forecast for tomorrow morning?",
            "Let's meet at the station, then walk to the market.",
            "The mother said sentence structure matters, and pretty much everything else too.",
            "Please summarise the production incident report before lunch",
            "Sent a quick message to Mike about the plan.",
            "Michael and Michelle will arrive on Thursday",
            "Terrific, that works for me.",
        ]
        for sentence in sentences {
            let corrected = await words.correct(sentence)
            XCTAssertEqual(corrected, sentence)
        }
    }

    func testPlainCapitalisedNameIsNotForcedOntoAnOrdinaryWord() async {
        let words = vocabulary(entities: ["Will"])
        let text = await words.correct("I will pick up the kids")
        XCTAssertEqual(text, "I will pick up the kids")
    }

    func testNearMatchOfALongTermIsFixed() async {
        let words = vocabulary(entities: ["Kubernetes"])
        let text = await words.correct("deploy it to kubernetis today")
        XCTAssertEqual(text, "deploy it to Kubernetes today")
    }

    func testAmbiguousRunIsLeftAlone() async {
        let words = vocabulary()
        words.wordList.add("Foobar", misheard: ["fubar"])
        words.wordList.add("Fubarz", misheard: ["fubar"])
        let text = await words.correct("this is fubar")
        XCTAssertEqual(text, "this is fubar")
    }

    // S5
    func testLearningACorrectionTeachesTheNextTranscript() async {
        let words = vocabulary()
        words.learn(heard: "length fuse", spelled: "Langfuse")
        XCTAssertEqual(words.wordList.terms, [WordTerm(term: "Langfuse", misheard: ["length fuse"])])
        let text = await words.correct("check length fuse")
        XCTAssertEqual(text, "check Langfuse")
    }

    // S6
    func testThrowingCorrectorDeliversRawText() async {
        let words = vocabulary(entities: ["IronPet"])
        words.corrector = { _, _ in throw CancellationError() }
        let text = await words.correct("open iron pet")
        XCTAssertEqual(text, "open iron pet")
    }

    func testSlowCorrectorIsCutOffAtTheBudget() async {
        let words = vocabulary(entities: ["IronPet"])
        words.budget = 0.15
        words.corrector = { text, _ in
            try await Task.sleep(for: .seconds(5))
            return text.uppercased()
        }
        let started = Date()
        let text = await words.correct("open iron pet")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(text, "open iron pet")
        XCTAssertLessThan(elapsed, 0.15 + 0.25)
    }

    func testPromptListsTermsWithinTheCaps() {
        let words = vocabulary(entities: (0..<300).map { "Term\($0)" })
        let prompt = words.prompt()
        XCTAssertNotNil(prompt)
        XCTAssertLessThanOrEqual(prompt?.count ?? 0, VoiceVocabulary.maxPromptCharacters)
        XCTAssertLessThanOrEqual(prompt?.components(separatedBy: ", ").count ?? 0, VoiceVocabulary.maxPromptTerms)
        XCTAssertNil(vocabulary().prompt())
    }
}
