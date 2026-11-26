import Foundation
import IronPetKit

/// A failure a route reports. `message` is the API's or the validator's text, unchanged.
package struct RemoteFailure: Error, Equatable {
    package var status: Int
    package var code: String
    package var message: String

    package static func invalid(_ message: String) -> RemoteFailure { RemoteFailure(status: 400, code: "invalid", message: message) }

    /// The HTTP status for an API error code.
    package static func status(for code: APIError.Code) -> Int {
        switch code {
        case .notFound: return 404
        case .invalid: return 400
        case .conflict: return 409
        case .unavailable: return 503
        case .unsupported: return 501
        case .failed: return 500
        }
    }

    package init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    /// Turns what a call to `IronPetAPI` throws into a failure.
    package init(_ error: Error) {
        if let failure = error as? RemoteFailure {
            self = failure
        } else if let task = error as? TaskError {
            self.init(status: 400, code: APIError.Code.invalid.rawValue, message: task.message)
        } else {
            let api = APIError.wrap(error)
            self.init(status: Self.status(for: api.code), code: api.code.rawValue, message: api.message)
        }
    }
}

/// The inbox routes, as calls on `IronPetAPI`. They answer with the `IronPetKit` types the phone decodes. The route paths keep the
/// `suggestions` name, so a phone and a Mac that are on different versions still reach each other: `accept` marks an item done and
/// `reject` removes it.
@MainActor
package struct RemoteTasks {
    package init(api: IronPetAPI) {
        self.api = api
    }

    package let api: IronPetAPI

    private var tasks: TasksAPI { api.tasks }

    private func available() throws {
        if let reason = tasks.unavailable { throw RemoteFailure(status: 503, code: "unavailable", message: DatabaseNotice.toolError(reason)) }
    }

    package func suggestions() throws -> [String: Any] {
        try available()
        return RemoteWire.object(SuggestionListResponse(suggestions: tasks.suggestions.map { RemoteSuggestion($0) }))
    }

    /// `POST /v1/suggestions`: an item the agent on a phone queued while the Mac was out of reach. `id` is the stable id the phone made
    /// when it queued the item, so a delivery that is sent again, or sent by a phone that never saw the answer, adds nothing twice, also
    /// after the user removed the item. The answer says whether the Mac added it, and the id the item has in the inbox.
    package func add(_ args: [String: Any], device: String) throws -> [String: Any] {
        try available()
        var args = args
        args["origin"] = ["kind": TaskSource.agent.rawValue, "ref": "iphone:\(device)", "reason": "Added by the agent on the user's iPhone"]
        switch TaskJSON.call(tasks, "add", args, by: "iphone") {
        case .failure(let error): throw RemoteFailure(status: 400, code: APIError.Code.invalid.rawValue, message: error.message)
        case .success(let value):
            let object = value as? [String: Any] ?? [:]
            let item = object["item"] as? [String: Any]
            var answer: [String: Any] = ["added": object["added"] as? Bool ?? false]
            if let id = item?["id"] as? String { answer["id"] = id }
            return answer
        }
    }

    /// Marks the item done. It leaves the list on the Mac and on every phone.
    package func accept(_ id: String) throws -> [String: Any] {
        try available()
        try tasks.done(id)
        return RemoteWire.object(RemoteDone(done: id))
    }

    package func reject(_ id: String, _ args: [String: Any]) throws -> [String: Any] {
        try available()
        try tasks.remove(RemoveSuggestionRequest(id: id, note: try args["note"].map { try TaskValidator.notes($0) }))
        return RemoteWire.object(RemoteRejected(rejected: id))
    }
}

extension RemoteSuggestion {
    package init(_ suggestion: TaskSuggestion) {
        let origin: String, detail: String
        switch suggestion.origin {
        case .meeting(let folder): origin = "meeting"; detail = folder.path
        case .automation(let id, let name): origin = "automation"; detail = "\(name) (\(id))"
        }
        self.init(id: suggestion.id, title: suggestion.title, created: suggestion.created, origin: origin, originDetail: detail, due: suggestion.due,
                  notes: suggestion.notes, url: suggestion.url?.absoluteString, waitingOn: suggestion.waitingOn,
                  sourceRef: suggestion.sourceRef.map { RemoteJSON(reference: $0) })
    }
}
