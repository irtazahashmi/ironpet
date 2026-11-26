import Foundation

/// One row of the links list in an inbox item's detail view.
package struct TaskLinkRow: Equatable {
    package init(link: TaskLink) {
        self.link = link
    }

    package let link: TaskLink
    package var symbol: String { link.symbol }

    /// The label, or a short form of the ref: the host of a URL, the ref itself otherwise.
    package var title: String {
        if let label = link.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty { return label }
        switch link.kind {
        case .url: return URL(string: link.ref)?.host ?? link.ref
        case .meeting: return link.ref
        }
    }

    package enum Action: Equatable {
        case openURL(URL)
        /// The meeting folder's name, which the Transcripts section opens.
        case openMeeting(String)
        case none
    }

    /// What clicking the row does. Web links must be http(s) because the database is a file anyone can edit.
    package var action: Action {
        switch link.kind {
        case .url:
            guard let url = URL(string: link.ref), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .none }
            return .openURL(url)
        case .meeting:
            return link.ref.isEmpty ? .none : .openMeeting(link.ref)
        }
    }
}
