import IronPetKit
import SwiftUI

/// The numbers and rules of the swipe that starts a reply. They are plain functions so a test can pin them without a gesture.
enum SwipeReply {
    /// How far the message follows a finger at most, and how much of the finger's travel it follows.
    static let maxPull: CGFloat = 72
    static let follow: CGFloat = 0.55
    /// The pull at which letting go starts a reply, and where the haptic fires.
    static let threshold: CGFloat = 44
    /// A swipe that starts this close to the left edge is the system's back swipe.
    static let edge: CGFloat = 28

    static func pull(_ travel: CGFloat) -> CGFloat { min(max(travel, 0) * follow, maxPull) }

    static func crossed(_ travel: CGFloat) -> Bool { pull(travel) >= threshold }

    /// A drag starts a reply swipe only when it goes right, is mostly flat and starts clear of the screen edge. A vertical drag is a
    /// scroll, and a swipe from the edge is the back swipe. A block that scrolls sideways is checked separately, on the touched view.
    static func begins(dx: CGFloat, dy: CGFloat, startX: CGFloat) -> Bool {
        dx > 0 && dx > abs(dy) * 2 && startX >= edge
    }
}

extension View {
    /// A right swipe on the message starts a reply, the same as Reply in its menu. Nil `onReply` leaves the view alone.
    func swipeToReply(_ onReply: (() -> Void)?) -> some View { modifier(SwipeToReply(onReply: onReply)) }
}

private struct SwipeToReply: ViewModifier {
    let onReply: (() -> Void)?
    @State private var travel: CGFloat = 0
    @State private var crossed = false

    func body(content: Content) -> some View {
        if let onReply {
            content
                .background(SwipeRecognizer(
                    onMove: { x in
                        travel = x
                        let now = SwipeReply.crossed(x)
                        if now != crossed { crossed = now }
                    },
                    onEnd: { reply in
                        crossed = false
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { travel = 0 }
                        if reply { onReply() }
                    }))
                .offset(x: SwipeReply.pull(travel))
                .background(alignment: .leading) { arrow }
                .sensoryFeedback(.impact(weight: .medium), trigger: crossed) { _, now in now }
        } else {
            content
        }
    }

    /// The reply arrow, uncovered as the message moves right. It grows and darkens until the pull is enough to reply.
    private var arrow: some View {
        let progress = min(SwipeReply.pull(travel) / SwipeReply.threshold, 1)
        return Image(systemName: SharedSymbols.reply)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(crossed ? Color.accentColor : Color.secondary)
            .scaleEffect(0.6 + 0.4 * progress)
            .opacity(progress)
            .padding(.leading, 4)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .overlay { if travel > 0 { Color.clear.accessibilityIdentifier("swipe-reply-arrow") } }
    }
}

/// A pan recognizer on the window that begins only for a right, flat drag that starts inside the row. A vertical drag never begins it, so
/// scrolling is untouched, and it never cancels another touch. A drag that starts on a view that scrolls sideways, such as a code block
/// or a table, is left to that view.
private struct SwipeRecognizer: UIViewRepresentable {
    let onMove: (CGFloat) -> Void
    let onEnd: (Bool) -> Void

    func makeUIView(context: Context) -> HolderView { HolderView() }

    func updateUIView(_ view: HolderView, context: Context) {
        view.onMove = onMove
        view.onEnd = onEnd
    }

    final class HolderView: UIView, UIGestureRecognizerDelegate {
        var onMove: (CGFloat) -> Void = { _ in }
        var onEnd: (Bool) -> Void = { _ in }
        private var engaged = false

        private lazy var pan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delegate = self
            return pan
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func willMove(toWindow newWindow: UIWindow?) {
            window?.removeGestureRecognizer(pan)
            newWindow?.addGestureRecognizer(pan)
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let window, gestureRecognizer === pan else { return false }
            let here = pan.location(in: window)
            let moved = pan.translation(in: window)
            let start = CGPoint(x: here.x - moved.x, y: here.y - moved.y)
            guard bounds.contains(convert(start, from: window)) else { return false }
            let speed = pan.velocity(in: window)
            guard SwipeReply.begins(dx: speed.x, dy: speed.y, startX: start.x) else { return false }
            var view = window.hitTest(start, with: nil)
            while let current = view {
                if let scroll = current as? UIScrollView, scroll.isScrollEnabled, scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                view = current.superview
            }
            engaged = true
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            guard engaged else { return }
            switch pan.state {
            case .changed:
                onMove(pan.translation(in: window).x)
            case .ended, .cancelled, .failed:
                engaged = false
                onEnd(pan.state == .ended && SwipeReply.crossed(pan.translation(in: window).x))
            default:
                break
            }
        }
    }
}

/// Hides the keyboard when a finger rests on the transcript. The long-press menu lifts after 0.5 s, and a keyboard that hides while it
/// lifts scrolls the transcript under it, so the lifted message is drawn over its neighbour. Hiding it at 0.25 s lets the layout settle
/// first. The recognizer sits on the window, recognizes next to every other gesture and never cancels a touch, so taps, scrolls and the
/// menu behave as before. A tap or a scroll ends the touch or moves it sooner than 0.25 s and changes nothing.
private struct KeyboardHider: UIViewRepresentable {
    func makeUIView(context: Context) -> HolderView { HolderView() }
    func updateUIView(_ view: HolderView, context: Context) {}

    final class HolderView: UIView, UIGestureRecognizerDelegate {
        private lazy var recognizer: UILongPressGestureRecognizer = {
            let press = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
            press.minimumPressDuration = 0.25
            press.allowableMovement = 6
            press.cancelsTouchesInView = false
            press.delaysTouchesBegan = false
            press.delaysTouchesEnded = false
            press.delegate = self
            return press
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func willMove(toWindow newWindow: UIWindow?) {
            window?.removeGestureRecognizer(recognizer)
            newWindow?.addGestureRecognizer(recognizer)
        }

        @objc private func held(_ press: UILongPressGestureRecognizer) {
            guard press.state == .began, bounds.contains(press.location(in: self)) else { return }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

extension View {
    /// Put on the transcript, whose frame is where a resting finger hides the keyboard.
    func hidesKeyboardOnHold() -> some View { background(KeyboardHider()) }
}
