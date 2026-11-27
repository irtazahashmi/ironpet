import Foundation
import IronPetKit

/// What the Inbox screens say about an item, worked out from stored fields only. The views draw these values and decide nothing.
extension TaskSuggestion {
    /// The open items in origin groups with the newest first. See `InboxGrouping.group`.
    package static func groups(_ items: [TaskSuggestion]) -> [InboxGroup<TaskSuggestion>] {
        InboxGrouping.group(items, kind: { $0.originKind.rawValue }, created: \.created, tie: \.id)
    }

    /// The chat thread the item came from: the first chat source, or the reference the item was filed with.
    package var chatThread: String? {
        for source in sources where source.kind == .chat {
            if let thread = InboxGrouping.chatThread(ref: source.ref) { return thread }
        }
        let ref = (sourceRef.map(TaskJSON.refValue) as? [String: Any])?["ref"] as? String
        return ref.flatMap(InboxGrouping.chatThread(ref:))
    }

    /// The reason stored with the item when it was filed.
    package var storedReason: String? {
        (sourceRef.map(TaskJSON.refValue) as? [String: Any])?["reason"] as? String
    }

    /// The line under the title, without the time.
    package var originLine: InboxOriginLine {
        InboxOriginLine.make(reason: storedReason, kind: originKind.rawValue, chatThread: chatThread)
    }

    /// The Sources section of the item page.
    package var sourceRows: [InboxSourceRow] {
        InboxSourceRow.rows(sources.map { .init(kind: $0.kind.rawValue, ref: $0.ref, url: $0.url?.absoluteString, label: $0.label) })
    }

    /// The address the Open button opens. Nil when the item has none, and then there is no button.
    package var openURL: URL? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// The names of the other places the item came from, as a row says them: "and Agent".
    package var otherSourcesLabel: String? {
        InboxGrouping.otherSources(sources.map { $0.label ?? InboxSource.displayName($0.kind) })
    }

    /// The notes with their surrounding blank space removed.
    package var shownNotes: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension ResolvedSuggestion {
    package var chatThread: String? {
        for source in sources where source.kind == .chat {
            if let thread = InboxGrouping.chatThread(ref: source.ref) { return thread }
        }
        return nil
    }

    /// "From a chat", with the chat as the link. The reason it was filed is not kept with a resolved item.
    package var originLine: InboxOriginLine {
        InboxOriginLine.make(reason: nil, kind: sources.first?.kind.rawValue ?? "agent", chatThread: chatThread)
    }

    package var sourceRows: [InboxSourceRow] {
        InboxSourceRow.rows(sources.map { .init(kind: $0.kind.rawValue, ref: $0.ref, url: $0.url?.absoluteString, label: $0.label) })
    }

    /// The first line of the page: "Resolved by Inbox scan at 16:31".
    package func statusLine(time: String) -> String { "Resolved by \(resolverLabel) at \(time)" }
}
