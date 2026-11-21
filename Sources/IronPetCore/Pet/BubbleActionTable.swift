import Foundation

/// The closures behind a bubble's controls, found by bubble id and control id. The Mac's bubble view and the remote `press` route
/// both run them from here, so a press does the same thing wherever it comes from.
@MainActor
package final class BubbleActionTable {
    package init() {}

    package struct Handlers {
        package init(actions: [String: () -> Void] = [:], lines: [String: () -> Void] = [:], tap: (() -> Void)? = nil) {
            self.actions = actions
            self.lines = lines
            self.tap = tap
        }

        package var actions: [String: () -> Void] = [:]
        package var lines: [String: () -> Void] = [:]
        package var tap: (() -> Void)?

        /// Whether every control the bubble lists has a closure. A control without one would do nothing when pressed.
        package func covers(_ bubble: Bubble) -> Bool {
            bubble.actions.allSatisfy { actions[$0.id] != nil }
                && bubble.lines.allSatisfy { lines[$0.id] != nil }
                && (tap != nil) == bubble.tappable
        }
    }

    private var table: [String: Handlers] = [:]

    package func register(_ handlers: Handlers, for bubble: String) { table[bubble] = handlers }

    package func unregister(_ bubble: String) { table[bubble] = nil }

    package func runAction(bubble: String, action: String) throws {
        guard let run = table[bubble]?.actions[action] else { throw APIError.notFound("no action \"\(action)\" on this bubble") }
        run()
    }

    package func runLine(bubble: String, line: String) throws {
        guard let run = table[bubble]?.lines[line] else { throw APIError.notFound("no line \"\(line)\" on this bubble") }
        run()
    }

    package func runTap(bubble: String) throws {
        guard let run = table[bubble]?.tap else { throw APIError.invalid("this bubble has no action") }
        run()
    }
}

/// A bubble together with the closures its controls run. Builders return one so a caller cannot list a button without its closure.
@dynamicMemberLookup
package struct BubbleDraft {
    package struct Button {
        package var id: String
        package var title: String
        package var style: Bubble.Action.Style = .normal
        package var run: () -> Void

        package init(_ id: String, _ title: String, style: Bubble.Action.Style = .normal, run: @escaping () -> Void) {
            self.id = id; self.title = title; self.style = style; self.run = run
        }
    }

    package struct Row {
        package init(id: String, symbol: String, tint: BubbleTint, text: String, run: @escaping () -> Void) {
            self.id = id
            self.symbol = symbol
            self.tint = tint
            self.text = text
            self.run = run
        }

        package var id: String
        package var symbol: String
        package var tint: BubbleTint
        package var text: String
        package var run: () -> Void
    }

    package private(set) var bubble: Bubble
    package private(set) var handlers: BubbleActionTable.Handlers

    package init(id: String, symbol: String, tint: BubbleTint, title: String, subtitle: String? = nil, body: String? = nil,
         lines: [Row] = [], actions: [Button] = [], onTap: (() -> Void)? = nil, expires: Date? = nil,
         contentKind: Bubble.ContentKind = .standard, macOnly: Bool = false) {
        bubble = Bubble(id: id, symbol: symbol, tint: tint, title: title, subtitle: subtitle, body: body,
                        lines: lines.map { Bubble.Line(id: $0.id, symbol: $0.symbol, tint: $0.tint, text: $0.text) },
                        actions: actions.map { Bubble.Action(id: $0.id, title: $0.title, style: $0.style) },
                        tappable: onTap != nil, expires: expires, contentKind: contentKind, macOnly: macOnly)
        handlers = BubbleActionTable.Handlers(actions: Dictionary(actions.map { ($0.id, $0.run) }, uniquingKeysWith: { first, _ in first }),
                                              lines: Dictionary(lines.map { ($0.id, $0.run) }, uniquingKeysWith: { first, _ in first }),
                                              tap: onTap)
        assert(Set(actions.map(\.id)).count == actions.count, "bubble \(id) lists two buttons with the same id")
        assert(Set(lines.map(\.id)).count == lines.count, "bubble \(id) lists two lines with the same id")
    }

    package subscript<T>(dynamicMember path: KeyPath<Bubble, T>) -> T { bubble[keyPath: path] }

    /// What a press on the bubble itself does. Setting it also marks the bubble tappable.
    package var onTap: (() -> Void)? {
        get { handlers.tap }
        set {
            handlers.tap = newValue
            bubble.tappable = newValue != nil
        }
    }
}
