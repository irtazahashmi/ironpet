import Foundation
import IronPetKit

/// The meeting routes, as calls on `IronPetAPI.meetings`. Summary and transcript text leaves the Mac here (SECURITY.md, "Meeting
/// transcripts record other people"). There is no route that serves an audio chunk and none that starts a recording: the phone can
/// read, ask about, rebuild and delete a meeting, stop the recording that is running, and upload an audio file to import.
@MainActor
package struct RemoteMeetings {
    package init(api: IronPetAPI) {
        self.api = api
    }

    package let api: IronPetAPI

    private var meetings: MeetingsAPI { api.meetings }

    package func list() -> [String: Any] {
        ["meetings": RemoteWire.array(meetings.list().map {
            RemoteMeeting(id: $0.id, date: $0.date, preview: $0.preview, hasSummary: $0.hasSummary, hasTranscript: $0.hasTranscript,
                          hasAudio: $0.hasAudio, active: $0.active, ref: $0.ref, title: $0.title)
        })]
    }

    package func state() -> [String: Any] {
        let status = meetings.status
        return RemoteWire.object(RemoteMeetingState(phase: status.phase, appName: status.appName, startedAt: status.startedAt,
                                                    chunksDone: status.chunksDone, chunksWaiting: status.chunksWaiting,
                                                    chunksFailed: status.chunksFailed, regenerating: meetings.regenerationID,
                                                    regenerationErrors: meetings.regenerationErrors))
    }

    /// The Markdown of one meeting's summary or transcript. A meeting without that file is a 404.
    package func text(_ id: String, _ kind: MeetingText) async throws -> [String: Any] {
        guard let text = try await meetings.text(MeetingTextRequest(id: id, kind: kind)) else {
            throw RemoteFailure(status: 404, code: "not_found", message: "this meeting has no \(kind.rawValue) yet")
        }
        return RemoteWire.object(RemoteMeetingText(id: id, text: text))
    }

    /// Starts the rebuild and answers at once, since a full rebuild transcribes every chunk again. `state()` shows it running and why it failed.
    package func regenerate(_ id: String, mode: String?) throws -> [String: Any] {
        let regeneration: MeetingRegeneration
        switch mode ?? "summary" {
        case "summary": regeneration = .summaryOnly
        case "full": regeneration = .full
        default: throw RemoteFailure.invalid("mode must be summary or full")
        }
        _ = try meetings.get(id)
        if let reason = meetings.regenerationBlocked(id, mode: regeneration) {
            throw RemoteFailure(status: 409, code: "conflict", message: reason)
        }
        let api = api
        Task { @MainActor in try? await api.meetings.regenerate(RegenerateMeetingRequest(id: id, mode: regeneration)) }
        return ["started": id]
    }

    package func ask(_ id: String) throws -> [String: Any] {
        try meetings.ask(id)
        return ["asked": id]
    }

    package func delete(_ id: String) throws -> [String: Any] {
        try meetings.delete(id)
        return ["deleted": id]
    }

    package func beginUpload(id: String, fileName: String, size: Int64) throws -> [String: Any] {
        RemoteWire.object(try meetings.beginUpload(id: id, fileName: fileName, size: size))
    }

    package func uploadStatus(_ id: String) throws -> [String: Any] { RemoteWire.object(try meetings.uploadStatus(id: id)) }

    package func uploadPart(_ id: String, offset: Int64, data: Data) throws -> [String: Any] {
        RemoteWire.object(try meetings.appendUpload(id: id, offset: offset, data: data))
    }

    package func completeUpload(_ id: String) throws -> [String: Any] {
        try meetings.completeUpload(id: id)
        return ["accepted": id]
    }

    package func storeChunk(id: String, index: Int, data: Data) throws -> [String: Any] {
        try meetings.storeChunk(id: id, index: index, data: data)
        return ["id": id, "index": index]
    }

    package func completeRecording(id: String, count: Int, startedAt: Date) throws -> [String: Any] {
        try meetings.completeRecording(id: id, count: count, startedAt: startedAt)
        return ["accepted": id]
    }

    /// Ends the recording that is running. With none running it is a 409.
    package func stop() throws -> [String: Any] {
        try meetings.stopRecording()
        return ["stopped": true]
    }
}
