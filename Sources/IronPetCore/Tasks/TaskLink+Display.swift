import Foundation
import enum IronPetKit.SharedSymbols

extension TaskLink {
    package var symbol: String {
        switch kind {
        case .url: return "safari"
        case .meeting: return SharedSymbols.meetings
        }
    }

    /// The tooltip, accessibility label and menu title for the link's button.
    package var help: String {
        let name = label?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        switch kind {
        case .url: return "Open \(name ?? URL(string: ref)?.host ?? "link")"
        case .meeting: return "Open \(name ?? "meeting")"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
