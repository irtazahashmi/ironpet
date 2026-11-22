import Foundation
import enum IronPetKit.SharedSymbols

extension TaskLink {
    package var symbol: String {
        switch kind {
        case .url: return "safari"
        case .file: return "folder"
        case .thread: return SharedSymbols.chat
        case .session: return "arrow.up.forward.app"
        }
    }

    /// The tooltip, accessibility label and menu title for the link's button.
    package var help: String {
        let name = label?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        switch kind {
        case .url: return "Open \(name ?? URL(string: ref)?.host ?? "link")"
        case .file: return "Show \(name ?? (ref as NSString).lastPathComponent) in Finder"
        case .thread: return "Open \(name ?? "chat thread")"
        case .session: return "Open \(name ?? "agent session")"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
