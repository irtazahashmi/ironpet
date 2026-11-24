import SwiftUI
import UIKit

/// The phone's own chat text size, a step count on top of the system's Dynamic Type size.
/// `small` is the size the chat had before this setting existed. The default is one step bigger.
enum ChatTextSize: String, CaseIterable, Identifiable {
    case small, standard, large, extraLarge

    static let storageKey = "chatTextSize"
    static let `default` = ChatTextSize.standard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: "Small"
        case .standard: "Default"
        case .large: "Large"
        case .extraLarge: "Extra large"
        }
    }

    /// Dynamic Type steps added to the system size.
    var steps: Int {
        switch self {
        case .small: 0
        case .standard: 1
        case .large: 2
        case .extraLarge: 3
        }
    }

    /// The system size moved up by `steps`, stopping at the largest size.
    func adjusted(_ size: DynamicTypeSize) -> DynamicTypeSize {
        let all = DynamicTypeSize.allCases
        guard let index = all.firstIndex(of: size) else { return size }
        return all[min(index + steps, all.count - 1)]
    }
}

extension DynamicTypeSize {
    /// The UIKit category with the same size, for fonts the composer builds itself.
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

/// Applies the chosen chat text size to a view and everything in it: the messages (through `ChatScale`) and the composer.
private struct ChatTextSizeModifier: ViewModifier {
    @AppStorage(ChatTextSize.storageKey) private var raw = ChatTextSize.default.rawValue
    @Environment(\.dynamicTypeSize) private var system

    func body(content: Content) -> some View {
        let size = (ChatTextSize(rawValue: raw) ?? .default).adjusted(system)
        content.dynamicTypeSize(size)
    }
}

extension View {
    func chatTextSize() -> some View { modifier(ChatTextSizeModifier()) }
}

/// A multiplier for the chat's point sizes that follows Dynamic Type. `ScaledMetric` rounds a value near 1 to coarse steps
/// (1.0, then 1.33), which hid the text size setting, so this reads the UIKit curve at full precision instead.
/// It is `ChatMetrics.scale` (the phone's 15 pt reply font against the Mac's 13.5 pt) at the system's default size, and each step above is the next Dynamic Type size.
@propertyWrapper
struct ChatScale: DynamicProperty {
    @Environment(\.dynamicTypeSize) private var size
    private let style: UIFont.TextStyle

    init(_ style: UIFont.TextStyle) { self.style = style }

    var wrappedValue: CGFloat { Self.value(style, size) }

    /// The multiplier for a text style at a Dynamic Type size. The composer calls this too, so its font matches the bubbles.
    static func value(_ style: UIFont.TextStyle, _ size: DynamicTypeSize) -> CGFloat {
        let metrics = UIFontMetrics(forTextStyle: style)
        let reference = UITraitCollection(preferredContentSizeCategory: .large)
        let current = UITraitCollection(preferredContentSizeCategory: size.contentSizeCategory)
        return ChatMetrics.scale * metrics.scaledValue(for: 100, compatibleWith: current) / metrics.scaledValue(for: 100, compatibleWith: reference)
    }
}
