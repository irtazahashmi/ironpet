import Foundation
#if canImport(Combine)
import Combine
#endif

@MainActor
package final class BubbleStore {
    package init() {}

    /// Fires before `bubbles` or `petOnLeft` change.
    package let changes = ChangeSignal()
    package private(set) var bubbles: [Bubble] = [] {
        willSet { changes.send() }
        didSet {
            // Dismissal, expiry and the limit all remove bubbles; a client that saw `bubble.shown` needs to hear about each.
            let kept = Set(bubbles.map(\.id))
            for gone in oldValue.map(\.id) where !kept.contains(gone) {
                actions.unregister(gone)
                events?.publish(.bubbleDismissed, id: gone)
            }
        }
    }
    /// The closures behind the bubbles' buttons, lines and taps.
    package let actions = BubbleActionTable()
    /// Which side of the bubbles the pet is on, so the tail points at him.
    package var petOnLeft = false { willSet { changes.send() } }
    private var hovering = false
    package static let limit = 4
    /// Called when a bubble goes away through `dismiss`, whether the user closed it or code did.
    package var onDismissed: ((String) -> Void)?
    /// When each id was last shown, for the past hour, so a summary can tell what came up while the user was away.
    package private(set) var shownAt: [String: Date] = [:]
    package var now: () -> Date = Date.init
    /// Where `bubble.shown` and `bubble.dismissed` are published for API clients, with the bubble's id.
    package weak var events: APIEventBus?

    package func show(_ draft: BubbleDraft) { show(draft.bubble, handlers: draft.handlers) }

    /// A bubble whose controls are all in `handlers`. A control without a closure would do nothing when pressed, so that stops a debug build.
    package func show(_ bubble: Bubble, handlers: BubbleActionTable.Handlers = .init()) {
        assert(handlers.covers(bubble), "bubble \(bubble.id) lists a button, line or tap that has no closure")
        actions.register(handlers, for: bubble.id)
        defer { events?.publish(.bubbleShown, id: bubble.id) }
        let now = now()
        let onScreen = Set(bubbles.map(\.id))
        shownAt = shownAt.filter { onScreen.contains($0.key) || now.timeIntervalSince($0.value) < 3600 }
        shownAt[bubble.id] = now
        var next = bubbles.filter { $0.id != bubble.id }
        next.append(bubble)
        while next.count > Self.limit {
            // The brief and recap stay until midnight, so they are usually the oldest with an expiry; pass over them first.
            let shortLived = next.indices.dropLast().first { next[$0].expires != nil && !next[$0].id.hasPrefix(WelcomeBack.digestPrefix) }
            next.remove(at: shortLived ?? next.firstIndex { $0.expires != nil } ?? next.firstIndex { $0.contentKind == .standard } ?? 0)
        }
        bubbles = next
    }

    /// The last time a bubble whose id starts with `prefix` was shown, within the past hour.
    package func lastShown(prefix: String) -> Date? {
        shownAt.filter { $0.key.hasPrefix(prefix) }.values.max()
    }

    package func dismiss(_ id: String) {
        guard bubbles.contains(where: { $0.id == id }) else { return }
        bubbles.removeAll { $0.id == id }
        onDismissed?(id)
    }

    /// Bubbles don't expire under the pointer, and get a few more seconds after it leaves.
    package func setHovering(_ on: Bool) {
        hovering = on
        guard !on else { return }
        let soon = Date().addingTimeInterval(4)
        bubbles = bubbles.map { b in
            var b = b
            if let e = b.expires, e < soon { b.expires = soon }
            return b
        }
    }

    package func sweep(now: Date = Date()) {
        guard !hovering else { return }
        let kept = bubbles.filter { $0.expires.map { $0 > now } ?? true }
        if kept.count != bubbles.count { bubbles = kept }
    }
}

#if canImport(Combine)

extension BubbleStore: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
