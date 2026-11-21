import Foundation

/// A named color for a bubble's icon. The view maps it to a platform color, so the data type stays free of UI frameworks.
package enum BubbleTint: String, Codable, CaseIterable {
    case accent, orange, blue, green, red, cyan, indigo, secondary
}

/// Something Ghost says next to himself: agent updates, approvals, alerts, reminders.
///
/// Plain data. The closures that run when a button, a line or the bubble itself is pressed live in a `BubbleActionTable`,
/// keyed by this bubble's id and the id of the control.
package struct Bubble: Identifiable, Codable, Equatable {
    package init(
        id: String,
        symbol: String,
        tint: BubbleTint,
        title: String,
        subtitle: String? = nil,
        body: String? = nil,
        lines: [Line] = [],
        actions: [Action] = [],
        tappable: Bool = false,
        expires: Date? = nil,
        contentKind: ContentKind = .standard,
        macOnly: Bool = false
    ) {
        self.id = id
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.lines = lines
        self.actions = actions
        self.tappable = tappable
        self.expires = expires
        self.contentKind = contentKind
        self.macOnly = macOnly
    }

    package struct Action: Identifiable, Codable, Equatable {
        package init(id: String, title: String, style: Style = .normal) {
            self.id = id
            self.title = title
            self.style = style
        }

        package enum Style: String, Codable { case primary, normal, destructive }
        /// Unique within the bubble.
        package var id: String
        package var title: String
        package var style: Style = .normal
    }

    /// A clickable line in a summary bubble, each opening its own thing.
    package struct Line: Identifiable, Codable, Equatable {
        package init(id: String, symbol: String, tint: BubbleTint, text: String) {
            self.id = id
            self.symbol = symbol
            self.tint = tint
            self.text = text
        }

        /// Unique within the bubble.
        package var id: String
        package var symbol: String
        package var tint: BubbleTint
        package var text: String
    }

    /// What the bubble draws.
    package enum ContentKind: String, Codable {
        /// The icon, title, text, lines and buttons.
        case standard
        /// The live meeting status, which replaces the icon, title and text.
        case meeting
    }

    /// Showing a bubble with the same id replaces the old one.
    package var id: String
    package var symbol: String
    package var tint: BubbleTint
    package var title: String
    package var subtitle: String?
    package var body: String?
    /// Shown instead of `body` when set.
    package var lines: [Line] = []
    package var actions: [Action] = []
    /// Whether pressing the bubble itself does something.
    package var tappable = false
    /// nil stays until answered or closed.
    package var expires: Date?
    package var contentKind: ContentKind = .standard
    /// The buttons decide something only the Mac may decide (a tool approval, a pairing request). The remote API sends the bubble
    /// without them and refuses a press, so a paired phone cannot approve what it is asked to approve itself.
    package var macOnly = false
}
