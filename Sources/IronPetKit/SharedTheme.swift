import Foundation

/// The colours both apps draw their surfaces with. The Mac's values are the reference, so the iPhone uses these instead of its
/// own system backgrounds, which are pure white and black.
public enum SharedTheme {
    /// The window and chat background as hex, for light and dark mode. The Mac's `windowBackgroundColor`.
    public static let windowLight: UInt32 = 0xFFFFFF
    public static let windowDark: UInt32 = 0x1E1E1E
    /// Opacity of `Color.primary` that fills a card, such as a task card or an expanded row.
    public static let cardOpacity = 0.05
    /// How much of `.ultraThinMaterial` the sidebar, tab bar and headers use: half, so the pattern behind shows through.
    public static let chromeStrength = 0.5
}

#if canImport(SwiftUI)
import SwiftUI

public extension SharedTheme {
    /// The window and chat background, light or dark with the colour scheme.
    static let window: Color = {
        #if canImport(UIKit)
        func rgb(_ hex: UInt32) -> (Double, Double, Double) {
            (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
        }
        let l = rgb(windowLight), d = rgb(windowDark)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: d.0, green: d.1, blue: d.2, alpha: 1) : UIColor(red: l.0, green: l.1, blue: l.2, alpha: 1) })
        #else
        // The Mac is the reference, so it keeps the system colour. The hex pair above is that colour's value on macOS 26,
        // for the iPhone, which has no equivalent.
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }()

    /// The fill of a card.
    static let card = Color.primary.opacity(cardOpacity)
}
#endif
