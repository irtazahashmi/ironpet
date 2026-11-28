import XCTest
@testable import IronPetKit

/// A Mac that keeps the bytes it was sent, and can lose the connection after a number of requests.
private final class UploadFakeMac: MeetingUploadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var held = Data()
    private(set) var size: Int64 = 0
    private(set) var completed = false
    private(set) var begins = 0
    private(set) var offsets: [Int64] = []
    /// Requests that still get through. Nil is no limit.
    var budget: Int?
    var refuseWith: String?
    /// The answer to a part is lost after the Mac stored it.
    var loseAnswerOfNextPart = false

    private func spend() throws {
        if let left = budget {
            guard left > 0 else { throw ClientError.transport("offline") }
            budget = left - 1
        }
    }

    func beginUpload(_ start: RemoteUploadStart) async throws -> RemoteUploadStatus {
        try lock.withLock {
            try spend()
            begins += 1
            if let refuseWith { throw ClientError.api(status: 400, code: "invalid", message: refuseWith) }
            size = start.size
            return RemoteUploadStatus(id: start.id, size: size, received: Int64(held.count))
        }
    }

    func uploadStatus(id: String) async throws -> RemoteUploadStatus {
        try lock.withLock { try spend(); return RemoteUploadStatus(id: id, size: size, received: Int64(held.count)) }
    }

    func sendUploadPart(id: String, offset: Int64, data: Data) async throws -> RemoteUploadStatus {
        try lock.withLock {
            try spend()
            guard offset == Int64(held.count) else { throw ClientError.api(status: 409, code: "conflict", message: "held \(held.count)") }
            held.append(data)
            offsets.append(offset)
            if loseAnswerOfNextPart { loseAnswerOfNextPart = false; throw ClientError.timedOut }
            return RemoteUploadStatus(id: id, size: size, received: Int64(held.count))
        }
    }

    func completeUpload(id: String) async throws {
        try lock.withLock {
            try spend()
            guard Int64(held.count) == size else { throw ClientError.api(status: 409, code: "conflict", message: "incomplete") }
            completed = true
        }
    }
}

final class MeetingUploadTests: XCTestCase {
    private var dir: URL!
    private var bytes: Data!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        bytes = Data((0..<1000).map { UInt8($0 % 251) })
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func source(_ name: String = "standup.m4a", _ data: Data? = nil) throws -> URL {
        let folder = dir.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try (data ?? bytes).write(to: url)
        return url
    }

    private func queue() -> MeetingUploadQueue { MeetingUploadQueue(folder: dir.appendingPathComponent("queue")) }

    // S3
    func testAnInterruptedUploadResumesFromTheLastConfirmedPartAndTheFileIsIdentical() async throws {
        let mac = UploadFakeMac()
        let uploader = MeetingUploader(partBytes: 100)
        let file = try source()
        mac.budget = 4   // begin and three parts
        do {
            try await uploader.upload(file: file, id: "u1", fileName: "standup.m4a", transport: mac)
            XCTFail("the connection dropped")
        } catch { XCTAssertEqual(error as? MeetingUploadFailure, .unreachable) }
        XCTAssertEqual(mac.held, bytes.prefix(300))
        mac.budget = nil
        try await uploader.upload(file: file, id: "u1", fileName: "standup.m4a", transport: mac)
        XCTAssertEqual(mac.held, bytes, "byte-identical")
        XCTAssertTrue(mac.completed)
        XCTAssertEqual(mac.offsets, Array(stride(from: Int64(0), to: 1000, by: 100)), "no part was sent twice")
    }

    // S3
    func testAPartTheMacStoredButNeverConfirmedIsNotSentTwice() async throws {
        let mac = UploadFakeMac()
        mac.loseAnswerOfNextPart = true
        let file = try source()
        let uploader = MeetingUploader(partBytes: 400)
        do { try await uploader.upload(file: file, id: "u2", fileName: "a.wav", transport: mac) } catch {
            XCTAssertEqual(error as? MeetingUploadFailure, .unreachable)
        }
        XCTAssertEqual(mac.held.count, 400)
        try await uploader.upload(file: file, id: "u2", fileName: "a.wav", transport: mac)
        XCTAssertEqual(mac.held, bytes)
        XCTAssertEqual(mac.offsets, [0, 400, 800])
    }

    // S5
    func testWhileTheMacIsUnreachableTheFileStaysAndGoesWhenItIsReachableAgain() async throws {
        let queue = queue()
        let entry = try queue.enqueue(copying: try source())
        let mac = UploadFakeMac()
        mac.budget = 0
        let uploader = MeetingUploader(partBytes: 300)
        let first = await queue.drain(using: mac, uploader: uploader)
        XCTAssertEqual(first, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.fileURL(for: entry).path), "the phone keeps its copy")
        XCTAssertEqual(queue.pending.map(\.id), [entry.id])
        // Dropped halfway: the copy is still there.
        mac.budget = 2
        _ = await queue.drain(using: mac, uploader: uploader)
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.fileURL(for: entry).path))
        XCTAssertFalse(mac.completed)
        // Reachable: the Mac confirms the whole file, and only then is the copy deleted.
        mac.budget = nil
        let done = await queue.drain(using: mac, uploader: uploader)
        XCTAssertEqual(done, 1)
        XCTAssertEqual(mac.held, bytes)
        XCTAssertTrue(mac.completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.fileURL(for: entry).path))
        XCTAssertEqual(queue.pending, [])
    }

    // S5
    func testTheCopyIsKeptWhenTheMacHasNotConfirmedTheWholeFile() async throws {
        let queue = queue()
        let entry = try queue.enqueue(copying: try source())
        let mac = UploadFakeMac()
        mac.budget = 5   // begin, 3 parts of 300 and the last part (100), then complete fails
        _ = await queue.drain(using: mac, uploader: MeetingUploader(partBytes: 300))
        XCTAssertEqual(mac.held, bytes)
        XCTAssertFalse(mac.completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.fileURL(for: entry).path), "all bytes sent but not confirmed")
    }

    // S4
    func testAFileOfTheWrongKindOrSizeIsRefusedWithTheMacsWordsAndNotQueued() throws {
        let queue = queue()
        XCTAssertThrowsError(try queue.enqueue(copying: try source("talk.ogg"))) {
            XCTAssertEqual(($0 as? MeetingUploadRefused)?.message, "ironpet imports m4a, mp3 and wav files. talk.ogg is not one of them.")
        }
        XCTAssertEqual(MeetingUploadLimits.refusal(fileName: "big.wav", size: MeetingUploadLimits.maxBytes + 1),
                       "big.wav is larger than the 1 GB limit for an imported file.")
        XCTAssertNil(MeetingUploadLimits.refusal(fileName: "exact.MP3", size: MeetingUploadLimits.maxBytes))
        XCTAssertEqual(MeetingUploadLimits.tooLong("long.m4a"), "long.m4a is longer than the 4 hour limit for an imported file.")
        XCTAssertEqual(queue.pending, [])
    }

    // S4
    func testAFileTheMacRefusesIsDeletedAndTheReasonStaysInTheList() async throws {
        let queue = queue()
        let entry = try queue.enqueue(copying: try source())
        let mac = UploadFakeMac()
        mac.refuseWith = "long.m4a is longer than the 4 hour limit for an imported file."
        _ = await queue.drain(using: mac)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.fileURL(for: entry).path))
        XCTAssertEqual(queue.pending.first?.failure, mac.refuseWith)
        queue.dismiss(entry.id)
        XCTAssertEqual(queue.pending, [])
    }

    // S2
    func testTheShareExtensionHandoffQueuesACopyThatTheAppFindsAfterARestart() throws {
        let shared = try source("Voice Memo.m4a")
        let fromExtension = queue()
        let entry = try fromExtension.enqueue(copying: shared)
        try FileManager.default.removeItem(at: shared)   // the system deletes its temporary file when the extension ends
        let inApp = queue()
        XCTAssertEqual(inApp.pending.map(\.fileName), ["Voice Memo.m4a"])
        XCTAssertEqual(try Data(contentsOf: inApp.fileURL(for: entry)), bytes)
    }

    // S2
    func testTheShareSheetHandoffKeepsAudioAddsAMissingExtensionAndRefusesTheRest() throws {
        let queue = queue()
        let memo = try source("Recording", bytes)
        let video = try source("clip.mov", bytes)
        let result = ShareHandoff.accept([(memo, "Recording", ["public.mpeg-4-audio", "public.audio"]), (video, "clip.mov", ["com.apple.quicktime-movie"])], into: queue)
        XCTAssertEqual(result.queued, 1)
        XCTAssertEqual(result.refusals, [MeetingUploadLimits.unsupportedType("clip.mov")])
        XCTAssertEqual(queue.pending.map(\.fileName), ["Recording.m4a"])
        XCTAssertEqual(ShareHandoff.fileName("call.WAV", typeIdentifiers: []), "call.WAV")
        XCTAssertEqual(ShareHandoff.fileName("zoom", typeIdentifiers: ["public.mp3"]), "zoom.mp3")
    }
}
