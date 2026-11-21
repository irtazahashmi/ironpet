import SwiftUI

/// Liquid Glass on iOS 26, blur materials on iOS 17 to 25. It mirrors `Sources/IronPet/Chat/GlassChrome.swift` on the Mac.
/// Every iOS 26 call sits behind `#available` for older systems, and behind `#if compiler(>=6.2)` because toolchains
/// before Xcode 26 don't have the iOS 26 SDK and can't compile those calls.
extension View {
    /// Fills `shape` with glass (iOS 26) or a material with a hairline edge (earlier).
    @ViewBuilder
    func chromeGlass<S: InsettableShape>(in shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            materialFill(shape)
        }
        #else
        materialFill(shape)
        #endif
    }

    private func materialFill<S: InsettableShape>(_ shape: S) -> some View {
        self.background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
    }

    /// Pins `content` to the bottom over the scroll view. On iOS 26 it is a scroll-edge bar, so content scrolling under it
    /// fades and blurs into the glass; earlier it is a plain safe-area inset.
    @ViewBuilder
    func glassBottomBar<V: View>(@ViewBuilder content: () -> V) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            self.safeAreaBar(edge: .bottom, spacing: 0, content: content)
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0, content: content)
        }
        #else
        self.safeAreaInset(edge: .bottom, spacing: 0, content: content)
        #endif
    }

    /// Content passing under the composer blurs and fades instead of being cut off at a line.
    @ViewBuilder
    func softBottomEdge() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            self.scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Glass that reacts to touch on iOS 26; the same material as `chromeGlass` earlier.
    @ViewBuilder
    func interactiveGlass<S: InsettableShape>(in shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            materialFill(shape)
        }
        #else
        materialFill(shape)
        #endif
    }

    /// A filled circle in `color`, tinted glass on iOS 26.
    @ViewBuilder
    func tintedCircle(_ color: Color) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            self.glassEffect(.regular.tint(color).interactive(), in: Circle())
        } else {
            self.background(color, in: Circle())
        }
        #else
        self.background(color, in: Circle())
        #endif
    }

    /// The look of the Mac's round glass button, for a label that is not a plain `Button`, such as a `Menu`.
    func glassCircle() -> some View {
        self.font(.system(size: 15, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: GlassCircleButtonStyle.size, height: GlassCircleButtonStyle.size)
            .contentShape(Circle())
            .interactiveGlass(in: Circle())
    }
}

/// Wraps neighbouring glass shapes so they sample and blend together on iOS 26.
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// A free-standing round glass button. The icon colour is set here, not left to the glass style, so it stays readable in light
/// and dark mode.
struct GlassCircleButtonStyle: ButtonStyle {
    static let size: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassCircle()
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
