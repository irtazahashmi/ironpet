import Foundation

/// A named color for a bubble's icon. The view maps it to a platform color, so the data type stays free of UI frameworks.
enum BubbleTint: String, Codable, CaseIterable {
    case accent, orange, blue, green, red, cyan, indigo, secondary
}

/// Something Ghost says next to himself: agent updates, approvals, alerts, reminders.
///
/// Plain data. The closures that run when a button, a line or the bubble itself is pressed live in a `BubbleActionTable`,
/// keyed by this bubble's id and the id of the control.
struct Bubble: Identifiable, Codable, Equatable {
    struct Action: Identifiable, Codable, Equatable {
        enum Style: String, Codable { case primary, normal, destructive }
        /// Unique within the bubble.
        var id: String
        var title: String
        var style: Style = .normal
    }

    /// A clickable line in a summary bubble, each opening its own thing.
    struct Line: Identifiable, Codable, Equatable {
        /// Unique within the bubble.
        var id: String
        var symbol: String
        var tint: BubbleTint
        var text: String
    }

    /// What the bubble draws.
    enum ContentKind: String, Codable {
        /// The icon, title, text, lines and buttons.
        case standard
        /// The live meeting status, which replaces the icon, title and text.
        case meeting
    }

    /// Showing a bubble with the same id replaces the old one.
    var id: String
    var symbol: String
    var tint: BubbleTint
    var title: String
    var subtitle: String?
    var body: String?
    /// Shown instead of `body` when set.
    var lines: [Line] = []
    var actions: [Action] = []
    /// Whether pressing the bubble itself does something.
    var tappable = false
    /// nil stays until answered or closed.
    var expires: Date?
    var contentKind: ContentKind = .standard
    /// The buttons decide something only the Mac may decide (a tool approval, a pairing request). The remote API sends the bubble
    /// without them and refuses a press, so a paired phone cannot approve what it is asked to approve itself.
    var macOnly = false
}
