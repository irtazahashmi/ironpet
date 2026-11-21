import Foundation
#if canImport(Combine)
import Combine
#endif

struct BubbleActionInfo: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    /// `primary`, `normal` or `destructive`.
    var style: String
}

struct BubbleLineInfo: Codable, Equatable, Identifiable {
    var id: String
    var symbol: String
    var text: String
}

/// A bubble as a client that cannot draw SwiftUI sees it.
struct BubbleInfo: Codable, Equatable, Identifiable {
    var id: String
    var symbol: String
    var title: String
    var subtitle: String?
    var body: String?
    var lines: [BubbleLineInfo]
    var actions: [BubbleActionInfo]
    var expires: Date?
    /// Whether clicking the bubble itself does something.
    var tappable: Bool
    /// The buttons are for the Mac alone. A remote client leaves them out and refuses a press.
    var macOnly: Bool = false
}

/// Presses one control of a bubble. With neither `action` nor `line`, it presses the bubble itself.
struct PressBubbleRequest: Codable, Equatable {
    var bubble: String
    var action: String?
    var line: String?
}

/// The bubbles beside the pet. A button press goes through the table of actions the bubbles registered, so any client can
/// press one, not only the view that draws it.
@MainActor
final class BubblesAPI {
    /// Fires before anything this API reads changes.
    let changes = ChangeSignal()
    private let store: BubbleStore
    private var forwarding: [ChangeToken] = []

    init(store: BubbleStore) {
        self.store = store
        forwarding = [
            store.changes.observe { [weak self] in self?.changes.send() },
        ]
    }

    /// The bubbles for the view that draws them. A bubble with live content has a `contentKind` the view draws itself, so a client that cannot draw it uses `list`.
    var bubbles: [Bubble] { store.bubbles }
    var petOnLeft: Bool { store.petOnLeft }

    func setPetOnLeft(_ left: Bool) { if store.petOnLeft != left { store.petOnLeft = left } }

    func setHovering(_ on: Bool) { store.setHovering(on) }

    func list() -> [BubbleInfo] {
        store.bubbles.map { bubble in
            BubbleInfo(id: bubble.id, symbol: bubble.symbol, title: bubble.title, subtitle: bubble.subtitle, body: bubble.body,
                       lines: bubble.lines.map { BubbleLineInfo(id: $0.id, symbol: $0.symbol, text: $0.text) },
                       actions: bubble.actions.map { BubbleActionInfo(id: $0.id, title: $0.title, style: Self.name($0.style)) },
                       expires: bubble.expires, tappable: bubble.tappable, macOnly: bubble.macOnly)
        }
    }

    func press(_ request: PressBubbleRequest) throws {
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
    func dismiss(_ id: String) throws {
        guard store.bubbles.contains(where: { $0.id == id }) else { throw APIError.notFound("no bubble with id \"\(id)\"") }
        store.dismiss(id)
    }

    private static func name(_ style: Bubble.Action.Style) -> String { style.rawValue }
}

#if canImport(Combine)

extension BubblesAPI: ObservableObject {
    nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
