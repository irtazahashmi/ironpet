import Foundation

/// The kinds of record that have a public id. The prefix says what the record is, so any id can be resolved without knowing where it came from.
package enum RecordKind: String, CaseIterable {
    case screen, meeting, chat, msg, task, auto, run, job, notif, page, claim, filter
}

/// A public id: the kind's prefix, an underscore and random lowercase hex digits, such as `task_9f3c1e5a07b2`. A new id has 12 digits
/// (48 bits), so two installs that never talk to each other can both create records and still not collide. Ids made before that have
/// six digits and stay valid, so `parse` accepts six or more. The digits never encode a title or a time, so an id never changes, and
/// a new id gets one more digit only when every try collides.
package enum RecordID {
    package static let digits: [Character] = Array("0123456789abcdef")
    /// The fewest digits an id can have. Ids from before ids became node-safe have this many.
    package static let minimumDigits = 6
    /// The digits in a new id.
    package static let newDigits = 12

    /// A new id for `kind` that `taken` does not report as used. `digit` supplies the random digits; tests pass a fixed one.
    package static func make(_ kind: RecordKind, taken: (String) throws -> Bool,
                             digit: () -> Character = { RecordID.digits.randomElement()! }) rethrows -> String {
        var length = newDigits
        while true {
            for _ in 0..<8 {
                let id = kind.rawValue + "_" + String((0..<length).map { _ in digit() })
                if try !taken(id) { return id }
            }
            length += 1
        }
    }

    /// The kind and digits of a public id. Nil for an old id such as `fix-login-bug` or `job-k3m9qa`, which is not in this form.
    package static func parse(_ id: String) -> (kind: RecordKind, hex: String)? {
        guard let underscore = id.firstIndex(of: "_"), let kind = RecordKind(rawValue: String(id[..<underscore])) else { return nil }
        let hex = String(id[id.index(after: underscore)...])
        guard hex.count >= minimumDigits, hex.allSatisfy({ digits.contains($0) }) else { return nil }
        return (kind, hex)
    }
}
