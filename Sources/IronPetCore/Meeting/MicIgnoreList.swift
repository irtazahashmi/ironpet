import Foundation

/// Rules for the user's "Never treat as a call" entries (`meetings.ignoredMicApps`). Entries are bundle id prefixes, like
/// the built-in list in `CallApps`.
package enum MicIgnoreList {
    package enum Rejection: Equatable, Error {
        case empty, tooShort, hasSpaces, alreadyBuiltIn, duplicate, ironpet

        package var message: String {
            switch self {
            case .empty: return "Enter a bundle id."
            case .tooShort: return "Use a bundle id with at least two parts, like com.example.app. A shorter prefix would hide real calls."
            case .hasSpaces: return "A bundle id has no spaces."
            case .alreadyBuiltIn: return "ironpet already ignores this app."
            case .duplicate: return "This app is already in the list."
            case .ironpet: return "ironpet never counts its own microphone use."
            }
        }
    }

    /// The entry trimmed, or the reason it cannot be used.
    package static func validate(_ entry: String, existing: [String] = [], ownBundleID: String? = nil) -> Result<String, Rejection> {
        let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .failure(.empty) }
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return .failure(.hasSpaces) }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count < 2 || parts.contains(where: \.isEmpty) { return .failure(.tooShort) }
        if let own = ownBundleID, own.caseInsensitiveCompare(value) == .orderedSame { return .failure(.ironpet) }
        if existing.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { return .failure(.duplicate) }
        if CallApps.isBuiltInIgnored(value) { return .failure(.alreadyBuiltIn) }
        return .success(value)
    }

    /// Keeps the valid entries in order and drops the rest, for a hand-edited config.json.
    package static func normalized(_ entries: [String], ownBundleID: String? = nil) -> [String] {
        var kept: [String] = []
        for entry in entries {
            if case .success(let value) = validate(entry, existing: kept, ownBundleID: ownBundleID) { kept.append(value) }
        }
        return kept
    }
}
