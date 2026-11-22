import AppKit
import IronPetCore

/// The accent colour the user picked in System Settings, for the phone to use on its links and controls.
enum MacAccent {
    /// The accent in light and dark mode, or nil for multicolour. Multicolour is the default, and `AppleAccentColor` is unset then,
    /// so the phone keeps its own system blue.
    @MainActor static func current(defaults: UserDefaults = .standard) -> PetAccent? {
        guard defaults.object(forKey: "AppleAccentColor") != nil else { return nil }
        guard let light = hex(of: .controlAccentColor, appearance: .aqua), let dark = hex(of: .controlAccentColor, appearance: .darkAqua) else { return nil }
        return PetAccent(light: light, dark: dark)
    }

    static func hex(of color: NSColor, appearance name: NSAppearance.Name) -> String? {
        var result: String?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            func byte(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
            result = String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
        }
        return result
    }
}
