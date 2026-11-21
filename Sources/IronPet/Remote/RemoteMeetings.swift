import Foundation
import IronPetKit

/// The meeting routes, as calls on `IronPetAPI.meetings`. Summary and transcript text leaves the Mac here (SECURITY.md, "Meeting
/// transcripts record other people"). There is no route that serves an audio chunk and none that starts a recording: the phone can
/// read, ask about, rebuild and delete a meeting, and stop the recording that is running.
@MainActor
struct RemoteMeetings {
    let api: IronPetAPI

    private var meetings: MeetingsAPI { api.meetings }

    func list() -> [String: Any] {
        ["meetings": RemoteWire.array(meetings.list().map {
            RemoteMeeting(id: $0.id, date: $0.date, preview: $0.preview, hasSummary: $0.hasSummary, hasTranscript: $0.hasTranscript,
                          hasAudio: $0.hasAudio, active: $0.active)
        })]
    }

    func state() -> [String: Any] {
        let status = meetings.status
        return RemoteWire.object(RemoteMeetingState(phase: status.phase, appName: status.appName, startedAt: status.startedAt,
                                                    chunksDone: status.chunksDone, chunksWaiting: status.chunksWaiting,
                                                    chunksFailed: status.chunksFailed, regenerating: meetings.regenerationID,
                                                    regenerationErrors: meetings.regenerationErrors))
    }

    /// The Markdown of one meeting's summary or transcript. A meeting without that file is a 404.
    func text(_ id: String, _ kind: MeetingText) async throws -> [String: Any] {
        guard let text = try await meetings.text(MeetingTextRequest(id: id, kind: kind)) else {
            throw RemoteFailure(status: 404, code: "not_found", message: "this meeting has no \(kind.rawValue) yet")
        }
        return RemoteWire.object(RemoteMeetingText(id: id, text: text))
    }

    /// Starts the rebuild and answers at once, since a full rebuild transcribes every chunk again. `state()` shows it running and why it failed.
    func regenerate(_ id: String, mode: String?) throws -> [String: Any] {
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

    func ask(_ id: String) throws -> [String: Any] {
        try meetings.ask(id)
        return ["asked": id]
    }

    func delete(_ id: String) throws -> [String: Any] {
        try meetings.delete(id)
        return ["deleted": id]
    }

    /// Ends the recording that is running. With none running it is a 409.
    func stop() throws -> [String: Any] {
        try meetings.stopRecording()
        return ["stopped": true]
    }
}
