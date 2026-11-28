import XCTest
@testable import IronPet
@testable import IronPetCore

/// The Mac transcoder against a real file: AVFoundation reads the length and streams 16 kHz mono samples in blocks.
final class MacAudioImportTests: XCTestCase {
    func testDurationAndStreamOfAWav() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-mac-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tone.wav")
        let seconds = 70
        try WAV.encode((0..<(seconds * WAV.sampleRate)).map { Int16($0 / 20 % 2 == 0 ? 8000 : -8000) }).write(to: file)

        let transcoder = MacAudioTranscoder()
        XCTAssertEqual(try XCTUnwrap(transcoder.duration(of: file)), Double(seconds), accuracy: 0.01)
        var total = 0
        var blocks = 0
        XCTAssertTrue(try transcoder.stream(from: file) { total += $0.count; blocks += 1 })
        XCTAssertEqual(total, seconds * WAV.sampleRate, accuracy: WAV.sampleRate / 10)
        XCTAssertGreaterThan(blocks, 1, "70 s arrive in more than one block")
    }

    func testAFileThatIsNotAudioHasNoDurationAndDoesNotStream() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-not-audio-\(UUID().uuidString).m4a")
        try Data("not audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transcoder = MacAudioTranscoder()
        XCTAssertNil(transcoder.duration(of: file))
        XCTAssertFalse(try transcoder.stream(from: file) { _ in XCTFail("no samples expected") })
    }
}
