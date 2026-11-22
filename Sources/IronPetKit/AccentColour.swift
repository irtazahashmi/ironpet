import Foundation

/// The Mac's accent colour as the phone reads it from `GET /v1/pet`.
public struct AccentColour: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }

    /// Reads `#RRGGBB`. Anything else, such as a short form or a stray character, is nil, so a bad value leaves the system blue in place.
    public init?(hex: String?) {
        guard var text = hex, text.hasPrefix("#") else { return nil }
        text.removeFirst()
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// The accent for light and dark mode, or nil when the light value is missing or malformed. A missing dark value reuses the light one.
    public static func pair(of pet: RemotePet?) -> (light: AccentColour, dark: AccentColour)? {
        guard let light = AccentColour(hex: pet?.accent) else { return nil }
        return (light, AccentColour(hex: pet?.accentDark) ?? light)
    }
}
