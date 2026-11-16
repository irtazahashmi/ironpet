import AppKit

extension NSWindow {
    /// Hides the minimize and zoom buttons, which the ironpet window does not support and would show greyed out.
    /// The close button stays. AppKit on recent macOS re-shows hidden buttons after layout, key changes and
    /// appearance changes, so call this again from `update()`.
    func hideInertWindowButtons() {
        for type in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            if let button = standardWindowButton(type), !button.isHidden { button.isHidden = true }
        }
    }
}
