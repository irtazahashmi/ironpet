import Foundation

/// A meeting's public id. The id lives in a marker file inside the meeting's folder, so a database that is rebuilt gets the same id
/// back, and the folder can be moved with its id. The folder's name stays the meeting's own key, as it always was.
package enum MeetingIdentity {
    package static let markerName = "meeting.id"

    /// The id of the meeting in `folder`. The first read assigns one and writes the marker; a marker that names a meeting id is
    /// adopted, and when the database already has a different id for that folder, the database's id wins and the marker follows it.
    package static func ref(folder: URL, records: RecordRefs) -> String? {
        let key = folder.lastPathComponent
        let marker = folder.appendingPathComponent(markerName)
        let stored = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref: String?
        if let stored, RecordID.parse(stored)?.kind == .meeting {
            ref = records.adopt(stored, .meeting, key)
        } else {
            ref = records.ref(.meeting, key)
        }
        if let ref, ref != stored {
            try? (ref + "\n").write(to: marker, atomically: true, encoding: .utf8)
        }
        return ref
    }
}
