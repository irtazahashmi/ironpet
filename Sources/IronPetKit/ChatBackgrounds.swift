import Foundation

/// The chat backgrounds the Mac offers in Settings, as data and as a drawing. The Mac and the iPhone app both draw from this one
/// definition, so a background looks the same on both. Built-ins are drawn in code, so neither app carries image files for them. The
/// soft colours stay close to the system background in brightness, which keeps text, links and code blocks as readable as on the
/// plain background.
public enum ChatBackgrounds {
    public static let defaultID = "default"
    public static let customID = "custom"

    public enum Doodle: CaseIterable, Sendable { case paw, ghost, star, bubble, leaf }

    public struct BuiltIn: Identifiable, Sendable {
        public let id: String
        public let name: String
        /// Top and bottom colours of the gradient, as hex, for light and dark mode.
        public let light: (UInt32, UInt32)
        public let dark: (UInt32, UInt32)
        /// Line colour of the doodles, as hex, for light and dark mode. Drawn at `inkOpacity` (120% of it in dark mode). Both are low enough that a link stays at 4.5:1 or better on a stroke.
        public let lightInk: UInt32
        public let darkInk: UInt32
        public let inkOpacity: Double
        /// Empty for a plain gradient.
        public let doodles: [Doodle]

        public init(id: String, name: String, light: (UInt32, UInt32), dark: (UInt32, UInt32), lightInk: UInt32, darkInk: UInt32,
                    inkOpacity: Double, doodles: [Doodle]) {
            self.id = id; self.name = name; self.light = light; self.dark = dark
            self.lightInk = lightInk; self.darkInk = darkInk; self.inkOpacity = inkOpacity; self.doodles = doodles
        }
    }

    public static let builtIns: [BuiltIn] = [
        BuiltIn(id: "dusk", name: "Dusk", light: (0xF6F8FD, 0xEEF2FB), dark: (0x1F2233, 0x181D2B),
                lightInk: 0x000000, darkInk: 0xFFFFFF, inkOpacity: 0, doodles: []),
        BuiltIn(id: "paws", name: "Paws", light: (0xF2FAF5, 0xE9F6EF), dark: (0x1A2A24, 0x15221D),
                lightInk: 0x2F6B4F, darkInk: 0xA8E0C6, inkOpacity: 0.08, doodles: [.paw, .star]),
        BuiltIn(id: "ghosts", name: "Ghosts", light: (0xF8F4FD, 0xF1ECFB), dark: (0x25203A, 0x1C1830),
                lightInk: 0x5B4A8C, darkInk: 0xC9BDF2, inkOpacity: 0.07, doodles: [.ghost, .star, .bubble]),
        BuiltIn(id: "chatter", name: "Chatter", light: (0xFEF7EF, 0xFBEFE2), dark: (0x2E2420, 0x241C19),
                lightInk: 0x9A5B2E, darkInk: 0xF0C7A0, inkOpacity: 0.08, doodles: [.bubble, .star, .paw]),
        BuiltIn(id: "leaves", name: "Leaves", light: (0xF4F9EF, 0xEBF4E1), dark: (0x1E2818, 0x182012),
                lightInk: 0x4B7A2E, darkInk: 0xBEE3A0, inkOpacity: 0.08, doodles: [.leaf, .star]),
    ]

    public static func builtIn(_ id: String) -> BuiltIn? { builtIns.first { $0.id == id } }
}

#if canImport(SwiftUI)
import SwiftUI

/// The picture behind a chat transcript. A built-in is drawn in code, `custom` shows `customImage` aspect-filled so it covers the
/// area and the overflow is cropped, and anything else, or a custom background whose image is missing, shows `fallback`. The caller
/// passes the platform's own window or system background as the fallback and the decoded image for `custom`.
public struct ChatBackgroundPicture: View {
    let id: String
    let customImage: Image?
    let fallback: Color
    let scale: CGFloat
    @Environment(\.colorScheme) private var scheme

    /// `scale` shrinks the doodles for thumbnails.
    public init(id: String, customImage: Image? = nil, fallback: Color, scale: CGFloat = 1) {
        self.id = id; self.customImage = customImage; self.fallback = fallback; self.scale = scale
    }

    public var body: some View {
        if let builtIn = ChatBackgrounds.builtIn(id) {
            BuiltInBackgroundView(builtIn: builtIn, dark: scheme == .dark, scale: scale).equatable()
        } else if id == ChatBackgrounds.customID, let customImage {
            Color.clear.overlay { customImage.resizable().scaledToFill() }.clipped()
        } else {
            fallback
        }
    }
}

/// A built-in background: the gradient and, for most, tiled doodles.
public struct BuiltInBackgroundView: View, Equatable {
    let builtIn: ChatBackgrounds.BuiltIn
    let dark: Bool
    let scale: CGFloat

    public init(builtIn: ChatBackgrounds.BuiltIn, dark: Bool, scale: CGFloat = 1) {
        self.builtIn = builtIn; self.dark = dark; self.scale = scale
    }

    public static func == (a: Self, b: Self) -> Bool { a.builtIn.id == b.builtIn.id && a.dark == b.dark && a.scale == b.scale }

    private static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    public var body: some View {
        let colors = dark ? builtIn.dark : builtIn.light
        let ink = Self.color(dark ? builtIn.darkInk : builtIn.lightInk).opacity(dark ? builtIn.inkOpacity * 1.2 : builtIn.inkOpacity)
        let doodles = builtIn.doodles
        let scale = scale
        // The canvas draws once per size or appearance change, not while the transcript scrolls over it.
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [Self.color(colors.0), Self.color(colors.1)]),
                                               startPoint: .zero, endPoint: CGPoint(x: size.width * 0.4, y: size.height)))
            guard !doodles.isEmpty else { return }
            let cell = 78 * scale
            let rows = Int(size.height / cell) + 2
            let cols = Int(size.width / cell) + 2
            for row in -1..<rows {
                for col in -1..<cols {
                    // A staggered grid with a fixed pseudo-random kind, tilt and nudge per cell, so the pattern tiles.
                    let seed = (row &* 7 &+ col &* 13) & 0xFF
                    let kind = doodles[((row &* 3 &+ col &* 5) % doodles.count + doodles.count) % doodles.count]
                    let x = (CGFloat(col) + (row & 1 == 0 ? 0.25 : 0.75)) * cell + CGFloat(seed % 7 - 3) * scale
                    let y = (CGFloat(row) + 0.5) * cell + CGFloat(seed % 5 - 2) * scale
                    var layer = context
                    layer.translateBy(x: x, y: y)
                    layer.rotate(by: .degrees(Double(seed % 9 - 4) * 5))
                    layer.scaleBy(x: scale, y: scale)
                    layer.stroke(Self.path(kind), with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// A doodle about 26 pt across, centered on the origin.
    static func path(_ kind: ChatBackgrounds.Doodle) -> Path {
        var p = Path()
        switch kind {
        case .paw:
            p.addEllipse(in: CGRect(x: -6, y: 1, width: 12, height: 9))
            for (x, y) in [(-9.0, -3.0), (-3.5, -8.0), (3.5, -8.0), (9.0, -3.0)] {
                p.addEllipse(in: CGRect(x: x - 2.4, y: y - 3, width: 4.8, height: 6))
            }
        case .ghost:
            p.move(to: CGPoint(x: -9, y: 10))
            p.addLine(to: CGPoint(x: -9, y: -2))
            p.addCurve(to: CGPoint(x: 9, y: -2), control1: CGPoint(x: -9, y: -16), control2: CGPoint(x: 9, y: -16))
            p.addLine(to: CGPoint(x: 9, y: 10))
            p.addLine(to: CGPoint(x: 4.5, y: 6))
            p.addLine(to: CGPoint(x: 0, y: 10))
            p.addLine(to: CGPoint(x: -4.5, y: 6))
            p.closeSubpath()
            p.addEllipse(in: CGRect(x: -5, y: -4, width: 2.4, height: 3))
            p.addEllipse(in: CGRect(x: 2.6, y: -4, width: 2.4, height: 3))
        case .star:
            for i in 0..<10 {
                let angle = Double(i) * .pi / 5 - .pi / 2
                let radius: CGFloat = i % 2 == 0 ? 10 : 4.2
                let point = CGPoint(x: radius * CGFloat(cos(angle)), y: radius * CGFloat(sin(angle)))
                if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
            p.closeSubpath()
        case .bubble:
            p.addRoundedRect(in: CGRect(x: -11, y: -9, width: 22, height: 15), cornerSize: CGSize(width: 6, height: 6))
            p.move(to: CGPoint(x: -4, y: 6))
            p.addLine(to: CGPoint(x: -7, y: 11))
            p.addLine(to: CGPoint(x: 1, y: 6))
        case .leaf:
            p.move(to: CGPoint(x: -9, y: 9))
            p.addCurve(to: CGPoint(x: 9, y: -9), control1: CGPoint(x: -12, y: -6), control2: CGPoint(x: 0, y: -12))
            p.addCurve(to: CGPoint(x: -9, y: 9), control1: CGPoint(x: 12, y: 4), control2: CGPoint(x: 0, y: 12))
            p.move(to: CGPoint(x: -9, y: 9))
            p.addLine(to: CGPoint(x: 3, y: -3))
        }
        return p
    }
}
#endif
