import IronPetKit
import XCTest
@testable import IronPetRemote

/// A Mac that is there or not, and keeps what it is sent.
private final class ReachableMac: MeetingUploadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var reachable = false
    private(set) var held = Data()
    private(set) var completed = false
    private var size: Int64 = 0

    func setReachable(_ value: Bool) { lock.withLock { reachable = value } }

    private func check() throws { if !reachable { throw ClientError.transport("offline") } }

    func beginUpload(_ start: RemoteUploadStart) async throws -> RemoteUploadStatus {
        try lock.withLock { try check(); size = start.size; return RemoteUploadStatus(id: start.id, size: size, received: Int64(held.count)) }
    }
    func uploadStatus(id: String) async throws -> RemoteUploadStatus {
        try lock.withLock { try check(); return RemoteUploadStatus(id: id, size: size, received: Int64(held.count)) }
    }
    func sendUploadPart(id: String, offset: Int64, data: Data) async throws -> RemoteUploadStatus {
        try lock.withLock { try check(); held.append(data); return RemoteUploadStatus(id: id, size: size, received: Int64(held.count)) }
    }
    func completeUpload(id: String) async throws { try lock.withLock { try check(); completed = true } }
}

@MainActor
final class MeetingUploadsModelTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-uploads-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func file(_ name: String, count: Int = 500) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 7, count: count).write(to: url)
        return url
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    // S1, S5
    func testAPickedFileWaitsWhileTheMacIsAwayAndGoesWhenItIsBackThenTheCopyIsDeleted() async throws {
        let mac = ReachableMac()
        let queue = MeetingUploadQueue(folder: dir.appendingPathComponent("queue"))
        let model = MeetingUploadsModel(queue: queue, transport: mac, retryDelay: .milliseconds(20))
        var confirmed = 0
        model.onConfirmed = { confirmed += 1 }
        model.add([try file("standup.m4a")])
        XCTAssertEqual(model.waiting.map(\.fileName), ["standup.m4a"])
        let copy = queue.fileURL(for: model.waiting[0])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "the file stays on the phone while the Mac is away")
        XCTAssertFalse(mac.completed)
        mac.setReachable(true)
        try await wait { model.waiting.isEmpty }
        XCTAssertEqual(mac.held.count, 500)
        XCTAssertTrue(mac.completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "deleted after the Mac confirmed the whole file")
        XCTAssertEqual(confirmed, 1)
    }

    // S4
    func testAFileOfAnotherKindIsRefusedWithTheMacsWords() throws {
        let model = MeetingUploadsModel(queue: MeetingUploadQueue(folder: dir.appendingPathComponent("queue")), transport: ReachableMac())
        model.add([try file("talk.ogg")])
        XCTAssertEqual(model.message, "ironpet imports m4a, mp3 and wav files. talk.ogg is not one of them.")
        XCTAssertEqual(model.pending, [])
    }

    // S2
    func testAFileTheShareExtensionQueuedIsFoundOnLaunch() throws {
        let folder = dir.appendingPathComponent("queue")
        _ = ShareHandoff.accept([(try file("memo.m4a"), "memo.m4a", ["public.mpeg-4-audio"])], into: MeetingUploadQueue(folder: folder))
        let model = MeetingUploadsModel(queue: MeetingUploadQueue(folder: folder), transport: ReachableMac())
        XCTAssertEqual(model.waiting.map(\.fileName), ["memo.m4a"])
    }
}
