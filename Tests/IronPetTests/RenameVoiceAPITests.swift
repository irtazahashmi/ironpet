import CryptoKit
import XCTest
@testable import IronPet
@testable import IronPetCore

@MainActor
final class RenameVoiceAPITests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-rename-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func testAPIRenamesTheVoiceAndItsMeetingsAndRefusesBadNames() throws {
        let key = SymmetricKey(size: .bits256)
        let store = VoiceStore(url: dir.appendingPathComponent("voices.enc"), key: { key })
        var embedding = [Float](repeating: 0, count: 256)
        embedding[1] = 1
        let voice = try XCTUnwrap(store.enroll(name: "Jonas Ruskanen", embedding: embedding, seconds: 120))
        _ = store.enroll(name: "Ana", embedding: embedding.reversed(), seconds: 120)

        let folder = dir.appendingPathComponent("meetings/2026-11-01-1000")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# Meeting x (Zoom)\n[10:00:01] Jonas Ruskanen: hi\n".write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)

        let controller = MeetingController()
        controller.voiceStore = store
        let api = MeetingsAPI(recorder: controller, library: MeetingLibrary(root: dir.appendingPathComponent("meetings")))

        for bad in ["", "   ", "ana"] {
            XCTAssertThrowsError(try api.renameVoice(voice.id, to: bad)) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
        }
        XCTAssertEqual(api.voiceprints().map(\.name).sorted(), ["Ana", "Jonas Ruskanen"])

        try api.renameVoice(voice.id, to: "Joonas Ruuskanen")
        XCTAssertEqual(api.voiceprints().map(\.name).sorted(), ["Ana", "Joonas Ruuskanen"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8),
                       "# Meeting x (Zoom)\n[10:00:01] Joonas Ruuskanen: hi\n")
    }
}
