import Foundation
#if canImport(Combine)
import Combine
#endif

package struct BubbleActionInfo: Codable, Equatable, Identifiable {
    package init(id: String, title: String, style: String) {
        self.id = id
        self.title = title
        self.style = style
    }

    package var id: String
    package var title: String
    /// `primary`, `normal` or `destructive`.
    package var style: String
}

package struct BubbleLineInfo: Codable, Equatable, Identifiable {
    package init(id: String, symbol: String, text: String) {
        self.id = id
        self.symbol = symbol
        self.text = text
    }

    package var id: String
    package var symbol: String
    package var text: String
}

/// A bubble as a client that cannot draw SwiftUI sees it.
package struct BubbleInfo: Codable, Equatable, Identifiable {
    package init(
        id: String,
        symbol: String,
        title: String,
        subtitle: String? = nil,
        body: String? = nil,
        lines: [BubbleLineInfo],
        actions: [BubbleActionInfo],
        expires: Date? = nil,
        tappable: Bool,
        macOnly: Bool = false
    ) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.lines = lines
        self.actions = actions
        self.expires = expires
        self.tappable = tappable
        self.macOnly = macOnly
    }

    package var id: String
    package var symbol: String
    package var title: String
    package var subtitle: String?
    package var body: String?
    package var lines: [BubbleLineInfo]
    package var actions: [BubbleActionInfo]
    package var expires: Date?
    /// Whether clicking the bubble itself does something.
    package var tappable: Bool
    /// The buttons are for the Mac alone. A remote client leaves them out and refuses a press.
    package var macOnly: Bool = false
}

/// Presses one control of a bubble. With neither `action` nor `line`, it presses the bubble itself.
package struct PressBubbleRequest: Codable, Equatable {
    package init(bubble: String, action: String? = nil, line: String? = nil) {
        self.bubble = bubble
        self.action = action
        self.line = line
    }

    package var bubble: String
    package var action: String?
    package var line: String?
}

/// The bubbles beside the pet. A button press goes through the table of actions the bubbles registered, so any client can
/// press one, not only the view that draws it.
@MainActor
package final class BubblesAPI {
    /// Fires before anything this API reads changes.
    package let changes = ChangeSignal()
    private let store: BubbleStore
    private var forwarding: [ChangeToken] = []

    package init(store: BubbleStore) {
        self.store = store
        forwarding = [
            store.changes.observe { [weak self] in self?.changes.send() },
        ]
    }

    /// The bubbles for the view that draws them. A bubble with live content has a `contentKind` the view draws itself, so a client that cannot draw it uses `list`.
    package var bubbles: [Bubble] { store.bubbles }
    package var petOnLeft: Bool { store.petOnLeft }

    package func setPetOnLeft(_ left: Bool) { if store.petOnLeft != left { store.petOnLeft = left } }

    package func setHovering(_ on: Bool) { store.setHovering(on) }

    package func list() -> [BubbleInfo] {
        store.bubbles.map { bubble in
            BubbleInfo(id: bubble.id, symbol: bubble.symbol, title: bubble.title, subtitle: bubble.subtitle, body: bubble.body,
                       lines: bubble.lines.map { BubbleLineInfo(id: $0.id, symbol: $0.symbol, text: $0.text) },
                       actions: bubble.actions.map { BubbleActionInfo(id: $0.id, title: $0.title, style: Self.name($0.style)) },
                       expires: bubble.expires, tappable: bubble.tappable, macOnly: bubble.macOnly)
        }
    }

    package func press(_ request: PressBubbleRequest) throws {
        guard let bubble = store.bubbles.first(where: { $0.id == request.bubble }) else {
            throw APIError.notFound("no bubble with id \"\(request.bubble)\"")
        }
        if let id = request.action {
            try store.actions.runAction(bubble: bubble.id, action: id)
        } else if let id = request.line {
            try store.actions.runLine(bubble: bubble.id, line: id)
        } else {
            try store.actions.runTap(bubble: bubble.id)
        }
        store.dismiss(bubble.id)
    }

    /// Closes a bubble without pressing anything.
    package func dismiss(_ id: String) throws {
        guard store.bubbles.contains(where: { $0.id == id }) else { throw APIError.notFound("no bubble with id \"\(id)\"") }
        store.dismiss(id)
    }

    private static func name(_ style: Bubble.Action.Style) -> String { style.rawValue }
}

#if canImport(Combine)

extension BubblesAPI: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
