import Foundation

/// What kind of page an entity has. `me` is the user's own page; the others come from what Ghost is told or sees.
package enum EntityType: String, CaseIterable, Codable {
    case me, person, project, org, tool, topic
}

/// An entity as the matcher sees it.
package struct EntityRecord: Equatable {
    package init(id: String, type: EntityType, name: String, aliases: [String] = [], identifiers: [String] = []) {
        self.id = id
        self.type = type
        self.name = name
        self.aliases = aliases
        self.identifiers = identifiers
    }

    package let id: String
    package let type: EntityType
    package let name: String
    package let aliases: [String]
    /// Exact keys that name one entity: a repo URL, an email address, a calendar attendee.
    package let identifiers: [String]
}

/// The outcome of matching a name against known entities.
package enum EntityMatch: Equatable {
    case found(String)
    /// No entity of that type has the name, so the caller creates one.
    case none
    /// More than one entity fits, so the caller asks rather than guess.
    case ambiguous([String])
}

/// Matches a name to an existing entity. A known identifier comes first, then a name or alias of the same type. A name is only
/// matched when it is unambiguous; the matcher never picks one of several.
package enum EntityMatcher {
    /// `type` nil matches entities of any kind, for a page someone asks for by name.
    package static func match(name: String, identifiers: [String] = [], type: EntityType? = nil, in entities: [EntityRecord]) -> EntityMatch {
        let keys = Set(identifiers.map(normalize).filter { !$0.isEmpty })
        let kept = entities.filter { entity in type.map { entity.type == $0 } ?? true }
        if !keys.isEmpty {
            let byIdentifier = kept.filter { entity in entity.identifiers.contains { id in keys.contains(normalize(id)) } }.map(\.id)
            if byIdentifier.count == 1 { return .found(byIdentifier[0]) }
            if byIdentifier.count > 1 { return .ambiguous(byIdentifier) }
        }
        let wanted = normalize(name)
        guard !wanted.isEmpty else { return .none }
        let ids = kept.filter { entity in ([entity.name] + entity.aliases).contains { normalize($0) == wanted } }.map(\.id)
        switch ids.count {
        case 1: return .found(ids[0])
        case 2...: return .ambiguous(ids)
        default: break
        }
        // Variants of the same name come next, each step only when the one before found nothing. A step that fits two pages is
        // ambiguous, because filing on the wrong page is worse than a duplicate.
        func decide(_ ids: [String]) -> EntityMatch? {
            ids.count == 1 ? .found(ids[0]) : (ids.count > 1 ? .ambiguous(ids) : nil)
        }
        let wantedKeys = Set(variantKeys(name))
        if let match = decide(kept.filter { entity in
            ([entity.name] + entity.aliases).contains { !wantedKeys.isDisjoint(with: variantKeys($0)) }
        }.map(\.id)) { return match }
        // An acronym of a multi-word name ("SSP" for "Self Service Portal") counts only when one page has those initials.
        let flat = fold(name)
        // People are left out: two letters like "MN" are too short to name one person.
        if !flat.contains(" "), (2...6).contains(flat.count) {
            if let match = decide(kept.filter { $0.type != .person && initials(of: $0.name) == flat }.map(\.id)) { return match }
        }
        // A cross-type lookup stops here: a looser rule must not file a note on a page of another type.
        guard type != nil else { return .none }
        // A surname or a first name that fits exactly one full name is that person. Two or more is ambiguous (`Ana` for "Ana Silva"
        // and "Ana Lopez").
        if !flat.contains(" ") {
            let fits = kept.filter { entity in
                guard entity.type == .person else { return false }
                let words = fold(entity.name).split(separator: " ").map(String.init)
                return words.count > 1 && (words.first == flat || words.last == flat)
            }.map(\.id)
            if let match = decide(fits) { return match }
        }
        // A small spelling difference: one edit on names of five or more characters. People are left out, because two people can
        // be named one letter apart ("Maya Chen" and "Maya Cheng").
        if flat.count >= 5 {
            let near = kept.filter { entity in
                entity.type != .person && ([entity.name] + entity.aliases).contains { other in
                    let key = fold(other)
                    return key.count >= 5 && isOneEditApart(flat, key)
                }
            }.map(\.id)
            if let match = decide(near) { return match }
        }
        return .none
    }

    /// True when two pages of the same type may be one entity: a shared name, alias or acronym, or a spelling one edit apart. The
    /// duplicate banner uses the same variant rules as matching.
    package static func mayBeSame(_ a: EntityRecord, _ b: EntityRecord) -> Bool {
        guard a.type == b.type, a.type != .me, a.id != b.id else { return false }
        let namesA = [a.name] + a.aliases, namesB = [b.name] + b.aliases
        let keysA = Set(namesA.flatMap(variantKeys)), keysB = Set(namesB.flatMap(variantKeys))
        if !keysA.isDisjoint(with: keysB) { return true }
        guard a.type != .person else { return false }
        if let initialsA = initials(of: a.name), keysB.contains(initialsA), (2...6).contains(initialsA.count) { return true }
        if let initialsB = initials(of: b.name), keysA.contains(initialsB), (2...6).contains(initialsB.count) { return true }
        return namesA.contains { x in
            let fx = fold(x)
            return fx.count >= 5 && namesB.contains { y in let fy = fold(y); return fy.count >= 5 && isOneEditApart(fx, fy) }
        }
    }

    /// Lowercase, no accents, and every run of other characters one space: "Rabbit-Checkout" and "rabbit checkout" fold alike.
    package static func fold(_ text: String) -> String {
        let plain = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return plain.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }

    /// The names a written name can be found by: the whole of it folded, the part before a bracketed acronym, and the acronym.
    /// "Self Service Portal (SSP)" gives "self service portal ssp", "self service portal" and "ssp".
    private static func variantKeys(_ text: String) -> [String] {
        var keys = [fold(text)]
        if let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close, close == text.index(before: text.endIndex) || text[text.index(after: close)...].allSatisfy(\.isWhitespace) {
            let inner = fold(String(text[text.index(after: open)..<close]))
            let base = fold(String(text[..<open]))
            if !base.isEmpty { keys.append(base) }
            if !inner.isEmpty, !inner.contains(" ") { keys.append(inner) }
        }
        return keys.filter { !$0.isEmpty }
    }

    /// The first letters of a name's words, for names of two or more words: "Self Service Portal" gives "ssp".
    private static func initials(of name: String) -> String? {
        // The key with the most words but no bracketed acronym is the shortest multi-word key.
        guard let source = variantKeys(name).filter({ $0.contains(" ") }).min(by: { $0.count < $1.count }) else { return nil }
        return String(source.split(separator: " ").compactMap(\.first))
    }

    /// True when the two strings differ by one inserted, removed or changed character, or one swap of neighbours.
    private static func isOneEditApart(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        // Names with a digit ("Org 1", "Org 2", "Q3 plan") differ by one character and are different things.
        guard a != b, abs(x.count - y.count) <= 1, !a.contains(where: \.isNumber), !b.contains(where: \.isNumber) else { return false }
        var i = 0
        while i < min(x.count, y.count), x[i] == y[i] { i += 1 }
        if x.count == y.count {
            if Array(x[(i + 1)...]) == Array(y[(i + 1)...]) { return true }
            return i + 1 < x.count && x[i] == y[i + 1] && x[i + 1] == y[i] && Array(x[(i + 2)...]) == Array(y[(i + 2)...])
        }
        let (long, short) = x.count > y.count ? (x, y) : (y, x)
        return Array(long[(i + 1)...]) == Array(short[i...])
    }

    /// The form names are compared in: lowercase, one space between words, no edge punctuation.
    package static func normalize(_ text: String) -> String {
        MemoryNote.normalized(text)
    }

    /// The id of a person's page, from the name as it was written.
    package static func personID(_ name: String) -> String {
        "person:" + normalize(name)
    }
}
