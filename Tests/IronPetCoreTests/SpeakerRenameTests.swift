import CryptoKit
import XCTest
@testable import IronPetCore

@MainActor
final class SpeakerRenameTests: XCTestCase {
    private var dir: URL!
    private var store: VoiceStore!
    private let key = SymmetricKey(size: .bits256)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = makeStore()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func makeStore() -> VoiceStore {
        let key = key
        return VoiceStore(url: dir.appendingPathComponent("voices.enc"), key: { key })
    }

    private func unit(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        v[axis] = 1
        return v
    }

    private func enroll(_ name: String, axis: Int) -> StoredVoice {
        store.enroll(name: name, embedding: unit(axis), seconds: 120)!
    }

    private func meeting(_ id: String, transcript: String, summary: String?) throws -> URL {
        let folder = dir.appendingPathComponent("meetings").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try transcript.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        if let summary { try summary.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8) }
        return folder
    }

    // S1
    func testRenameKeepsTheVoiceprintAndSurvivesAReopen() throws {
        let voice = enroll("Jonas Ruskanen", axis: 1)
        let old = try store.rename(id: voice.id, to: "  Joonas Ruuskanen ")
        XCTAssertEqual(old, "Jonas Ruskanen")

        let reopened = makeStore().voices()
        XCTAssertEqual(reopened.count, 1)
        XCTAssertEqual(reopened[0].name, "Joonas Ruuskanen")
        XCTAssertEqual(reopened[0].id, voice.id)
        XCTAssertEqual(reopened[0].centroid, voice.centroid)
        XCTAssertEqual(reopened[0].seconds, voice.seconds)
        XCTAssertEqual(reopened[0].confirmedMeetings, voice.confirmedMeetings)
        // The file stays encrypted.
        let raw = try Data(contentsOf: dir.appendingPathComponent("voices.enc"))
        XCTAssertNil(raw.range(of: Data("Joonas".utf8)))
    }

    // S4
    func testRefusedNamesChangeNothing() throws {
        let jonas = enroll("Jonas Ruskanen", axis: 1)
        _ = enroll("Ana", axis: 2)
        let before = try Data(contentsOf: dir.appendingPathComponent("voices.enc"))
        XCTAssertThrowsError(try store.rename(id: jonas.id, to: "")) { XCTAssertEqual($0 as? VoiceStore.RenameError, .emptyName) }
        XCTAssertThrowsError(try store.rename(id: jonas.id, to: "   ")) { XCTAssertEqual($0 as? VoiceStore.RenameError, .emptyName) }
        XCTAssertThrowsError(try store.rename(id: jonas.id, to: "ana")) { XCTAssertEqual($0 as? VoiceStore.RenameError, .nameTaken) }
        XCTAssertThrowsError(try store.rename(id: "nope", to: "Zed")) { XCTAssertEqual($0 as? VoiceStore.RenameError, .notFound) }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("voices.enc")), before)
    }

    func testRenamingToACaseVariantOfItsOwnNameIsAllowed() throws {
        let voice = enroll("jonas", axis: 1)
        try store.rename(id: voice.id, to: "Jonas")
        XCTAssertEqual(store.voices().map(\.name), ["Jonas"])
    }

    // S2
    func testPastMeetingsOfThatVoiceAreRewrittenAndNothingElse() throws {
        let mine = try meeting("2026-11-01-1000",
            transcript: "# Meeting 2026-11-01 10:00 (Zoom)\n[10:00:01] Jonas Ruskanen: I am Jonas Ruskanen.\n[10:00:09] Ana: Hi Jonas Ruskanen\n[10:00:12] Jonas Ruskanenko: not him\n",
            summary: "## Summary\nJonas Ruskanen met Ana. Jonas Ruskanenko joined.\n")
        try "old Jonas Ruskanen\n".write(to: mine.appendingPathComponent("summary.prev.md"), atomically: true, encoding: .utf8)
        let other = try meeting("2026-11-02-1000",
            transcript: "# Meeting 2026-11-02 10:00 (Zoom)\n[10:00:01] Ana: we talked about Jonas Ruskanen\n",
            summary: "Mentions Jonas Ruskanen.\n")

        let outcome = SpeakerRename.apply(root: dir.appendingPathComponent("meetings"), from: "Jonas Ruskanen", to: "Joonas Ruuskanen")
        XCTAssertEqual(outcome, SpeakerRename.Outcome(meetings: 1, failed: 0))

        let transcript = try String(contentsOf: mine.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertEqual(transcript, "# Meeting 2026-11-01 10:00 (Zoom)\n[10:00:01] Joonas Ruuskanen: I am Jonas Ruskanen.\n[10:00:09] Ana: Hi Jonas Ruskanen\n[10:00:12] Jonas Ruskanenko: not him\n")
        let summary = try String(contentsOf: mine.appendingPathComponent("summary.md"), encoding: .utf8)
        XCTAssertEqual(summary, "## Summary\nJoonas Ruuskanen met Ana. Jonas Ruskanenko joined.\n")
        XCTAssertEqual(try String(contentsOf: mine.appendingPathComponent("summary.prev.md"), encoding: .utf8), "old Joonas Ruuskanen\n")
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("transcript.md"), encoding: .utf8),
                       "# Meeting 2026-11-02 10:00 (Zoom)\n[10:00:01] Ana: we talked about Jonas Ruskanen\n")
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("summary.md"), encoding: .utf8), "Mentions Jonas Ruskanen.\n")
    }

    func testRegexCharactersInANameAreLiteral() {
        XCTAssertEqual(SpeakerRename.renameNames(in: "A.B and AxB", from: "A.B", to: "C$1"), "C$1 and AxB")
    }

    // S3
    func testTheNextMeetingLabelsTheVoiceWithTheNewName() throws {
        let voice = enroll("Jonas Ruskanen", axis: 1)
        try store.rename(id: voice.id, to: "Joonas Ruuskanen")
        var table = MeetingSpeakerTable()
        let chunk = ChunkDiarization(speakers: [ChunkSpeaker(localId: "a", embedding: unit(1), turns: [0...2])])
        _ = table.link(chunk, chunkURL: dir.appendingPathComponent("them-001.wav"), store: store.candidates)
        XCTAssertEqual(table.speakers.first?.name, "Joonas Ruuskanen")
        XCTAssertEqual(table.speakers.first?.personId, voice.id)
    }
}
