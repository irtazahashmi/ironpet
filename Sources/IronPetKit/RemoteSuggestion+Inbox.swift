import Foundation

/// What the phone's Inbox says about an item, from the fields the Mac sends. The logic is the one the Mac's Inbox uses
/// (`InboxPresentation.swift`), so both screens group, name and link an item the same way. Every field is optional on the wire, so a
/// Mac on another version still gives a list.
extension RemoteSuggestion {
    /// The kind of place the item came from: its first source, or for a Mac that sends no sources the origin (`meeting`, else `automation`).
    public var groupKind: String {
        if let first = sources.first?.kind, !first.isEmpty { return first }
        return origin == "meeting" ? "meeting" : "automation"
    }

    /// The group an item belongs to. See `InboxGrouping.group`.
    public static func groups(_ items: [RemoteSuggestion]) -> [InboxGroup<RemoteSuggestion>] {
        InboxGrouping.group(items, kind: \.groupKind, created: \.created, tie: \.id)
    }

    /// The address the Open button opens. Nil when the item has none, and then there is no button.
    public var openURL: URL? {
        guard let url, let link = URL(string: url), ["http", "https"].contains(link.scheme?.lowercased() ?? ""), link.host?.isEmpty == false else { return nil }
        return link
    }

    private var reference: [String: RemoteJSON]? {
        if case .object(let object)? = sourceRef { return object }
        return nil
    }

    /// The reason stored with the item when it was filed.
    public var storedReason: String? {
        if case .string(let reason)? = reference?["reason"] { return reason }
        return nil
    }

    /// The chat thread the item came from: the first chat source, or the reference the item was filed with.
    public var chatThread: String? {
        for source in sources where source.kind == "chat" {
            if let thread = InboxGrouping.chatThread(ref: source.ref) { return thread }
        }
        if case .string(let ref)? = reference?["ref"] { return InboxGrouping.chatThread(ref: ref) }
        return nil
    }

    /// The line under the title, without the time.
    public var originLine: InboxOriginLine {
        InboxOriginLine.make(reason: storedReason, kind: groupKind, chatThread: chatThread)
    }

    /// The Sources section of the item page.
    public var sourceRows: [InboxSourceRow] {
        if sources.isEmpty { return InboxSourceRow.rows([.init(kind: groupKind, ref: originDetail ?? "", url: url, label: nil)]) }
        return InboxSourceRow.rows(sources.map { .init(kind: $0.kind, ref: $0.ref, url: $0.url, label: $0.label) })
    }

    /// The names of the other places the item came from, as a row says them: "and Agent".
    public var otherSourcesLabel: String? {
        InboxGrouping.otherSources(sources.map { $0.label ?? InboxKinds.title($0.kind) })
    }

    /// The notes with their surrounding blank space removed.
    public var shownNotes: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }
}
