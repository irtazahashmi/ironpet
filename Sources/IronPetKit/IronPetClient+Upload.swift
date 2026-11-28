import Foundation

/// The resumable upload of an audio file, which becomes a meeting on the Mac.
extension IronPetClient: MeetingUploadTransport {
    public func beginUpload(_ start: RemoteUploadStart) async throws -> RemoteUploadStatus {
        try decode(RemoteUploadStatus.self, from: try await perform(request("POST", APIPath.meetingUploads, body: try JSONEncoder().encode(start))))
    }

    public func uploadStatus(id: String) async throws -> RemoteUploadStatus {
        try await get(RemoteUploadStatus.self, APIPath.meetingUpload(id))
    }

    /// Sends the bytes that start at `offset`. A 409 means the Mac holds a different amount: ask `uploadStatus`.
    public func sendUploadPart(id: String, offset: Int64, data: Data) async throws -> RemoteUploadStatus {
        var put = request("PUT", APIPath.meetingUpload(id), query: [URLQueryItem(name: "offset", value: String(offset))],
                          headers: ["Content-Type": "application/octet-stream"])
        put.httpBody = data
        return try decode(RemoteUploadStatus.self, from: try await perform(put))
    }

    /// Asks the Mac to check the whole file and import it. The answer means the Mac holds every byte.
    public func completeUpload(id: String) async throws {
        _ = try await perform(request("POST", APIPath.completeMeetingUpload(id), body: Data("{}".utf8)))
    }
}

/// The chunks of a room recording made on the phone.
extension IronPetClient: MeetingRecordingTransport {
    public func sendRecordingChunk(id: String, index: Int, data: Data) async throws {
        var put = request("PUT", APIPath.meetingRecordingChunk(id, index: index), headers: ["Content-Type": "application/octet-stream"])
        put.httpBody = data
        _ = try await perform(put)
    }

    public func completeRecording(id: String, count: Int, startedAt: Date) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["count": count, "startedAt": startedAt.timeIntervalSince1970])
        _ = try await perform(request("POST", APIPath.completeMeetingRecording(id), body: body))
    }
}
