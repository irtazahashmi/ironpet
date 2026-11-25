import Foundation
import IronPetKit

/// The record route, `GET /v1/records/:id`: the record a public id in chat names, for the phone to show. The answer has the kind, the
/// ref and the key, plus the record's fields when its kind has a reader (captures, notifications, meetings, chats, messages) or it is a
/// task. A kind with neither answers with its three keys only, and the phone says to open it on the Mac.
extension RemoteResources {
    package func record(_ id: String) async throws -> [String: Any] {
        guard let records = api.records else { throw RemoteFailure(status: 503, code: APIError.Code.unavailable.rawValue, message: "record ids are not available right now") }
        let found: RecordResolver.Found
        switch records.resolve(id) {
        case .success(let value): found = value
        case .failure(let error): throw RemoteFailure(status: 404, code: APIError.Code.notFound.rawValue, message: error.message)
        }
        var object: [String: Any] = ["kind": found.kind.rawValue, "ref": found.ref, "key": found.key]
        if let reading = await records.read(found) {
            switch reading {
            case .success(let fields): object.merge(fields) { _, new in new }
            case .failure(let error): throw RemoteFailure(status: 404, code: APIError.Code.notFound.rawValue, message: error.message)
            }
        } else if found.kind == .task {
            object.merge(try RemoteTasks(api: api, by: "remote:\(device)").get(found.key)) { _, new in new }
        }
        return object
    }
}
