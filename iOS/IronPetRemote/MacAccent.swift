import SwiftUI

private struct MacAccentKey: EnvironmentKey {
    static let defaultValue = Color.accentColor
}

extension EnvironmentValues {
    /// The Mac's accent colour, or the system accent when the Mac sent none. Controls that draw the accent themselves read this,
    /// because `Color.accentColor` does not reliably follow `.tint(_:)`.
    var macAccent: Color {
        get { self[MacAccentKey.self] }
        set { self[MacAccentKey.self] = newValue }
    }
}
