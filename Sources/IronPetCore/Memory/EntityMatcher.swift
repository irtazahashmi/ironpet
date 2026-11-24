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
        case 0: return .none
        case 1: return .found(ids[0])
        default: return .ambiguous(ids)
        }
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
