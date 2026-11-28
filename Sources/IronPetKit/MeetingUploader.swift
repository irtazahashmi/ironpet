import Foundation

/// The four calls an upload makes. `IronPetClient` is the real one, tests pass a fake.
public protocol MeetingUploadTransport: Sendable {
    func beginUpload(_ start: RemoteUploadStart) async throws -> RemoteUploadStatus
    func uploadStatus(id: String) async throws -> RemoteUploadStatus
    func sendUploadPart(id: String, offset: Int64, data: Data) async throws -> RemoteUploadStatus
    func completeUpload(id: String) async throws
}

/// What stopped an upload.
public enum MeetingUploadFailure: Error, Equatable {
    /// The Mac could not be reached, or answered with an error that a later try may fix. The file stays queued.
    case unreachable
    /// The Mac refused the file. The text is the Mac's, which is the text the Mac's own import shows.
    case refused(String)
}

/// Sends one file in parts. It always asks the Mac how much it holds and continues from there, so a dropped connection costs at most
/// the part that was in flight, and a part the Mac got but never confirmed is not sent twice.
public struct MeetingUploader: Sendable {
    public var partBytes: Int

    public init(partBytes: Int = MeetingUploadLimits.partBytes) { self.partBytes = partBytes }

    /// Uploads `file` as upload `id` and returns once the Mac confirmed the whole file. Throws `MeetingUploadFailure`.
    public func upload(file: URL, id: String, fileName: String, transport: any MeetingUploadTransport) async throws {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? -1
        guard size >= 0 else { throw MeetingUploadFailure.refused(MeetingUploadLimits.unreadable(fileName)) }
        var held: RemoteUploadStatus
        do { held = try await transport.beginUpload(RemoteUploadStart(id: id, fileName: fileName, size: size)) } catch { throw Self.classify(error) }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: file) } catch { throw MeetingUploadFailure.refused(MeetingUploadLimits.unreadable(fileName)) }
        defer { try? handle.close() }
        var conflicts = 0
        while held.received < size {
            try Task.checkCancellation()
            do {
                try handle.seek(toOffset: UInt64(held.received))
                let data = try handle.read(upToCount: partBytes) ?? Data()
                guard !data.isEmpty else { throw MeetingUploadFailure.refused(MeetingUploadLimits.unreadable(fileName)) }
                held = try await transport.sendUploadPart(id: id, offset: held.received, data: data)
            } catch let error as ClientError {
                // The Mac holds a different amount than the phone thought: take its number and go on from there.
                guard case .api(409, _, _) = error, conflicts < 3 else { throw Self.classify(error) }
                conflicts += 1
                do { held = try await transport.uploadStatus(id: id) } catch { throw Self.classify(error) }
            } catch let failure as MeetingUploadFailure {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Self.classify(error)
            }
        }
        do { try await transport.completeUpload(id: id) } catch { throw Self.classify(error) }
    }

    /// A 4xx other than a timeout, a conflict or the rate limit means the Mac looked at the file or the request and said no.
    static func classify(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let error = error as? ClientError, case .api(let status, _, let message) = error, (400..<500).contains(status),
           ![401, 404, 408, 409, 423, 429].contains(status) {
            return MeetingUploadFailure.refused(message)
        }
        return MeetingUploadFailure.unreachable
    }
}
