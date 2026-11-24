import AppKit
import ApplicationServices
import IronPetCore

/// Reads the frontmost app's text selection once, when the chat opens. Never prompts for Accessibility and never touches
/// the pasteboard.
@MainActor
enum FrontSelectionReader {
    /// The selection in `app`, or nil when Accessibility is not trusted, the app is ironpet or denied, the focused field
    /// is secure, or nothing is selected.
    static func read(
        from app: NSRunningApplication?,
        ownBundleId: String = Bundle.main.bundleIdentifier ?? "com.ironpet.app",
        excludedApps: [String]? = nil,
        isTrusted: () -> Bool = { AXIsProcessTrusted() }
    ) -> FrontSelection? {
        guard isTrusted(), let app, app.bundleIdentifier != ownBundleId else { return nil }
        let excludedApps = excludedApps ?? ConfigStore.shared.config.screenCapture.excludedApps
        let bundleId = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? bundleId
        guard !bundleId.isEmpty || !name.isEmpty else { return nil }
        let captureApp = CaptureApp(bundleId: bundleId, name: name, pid: app.processIdentifier)
        if CaptureFloor.deniesApp(bundleId) { return nil }
        if excludedApps.contains(bundleId)
            || excludedApps.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return nil
        }
        let root = AXCaptureSource().appElement(for: captureApp)
        guard let focused = AXCaptureSource.element(root, "AXFocusedUIElement") else { return nil }
        let role = bare(AXCaptureSource.string(focused, "AXRole"))
        let subrole = bare(AXCaptureSource.string(focused, "AXSubrole"))
        if AXNode(role: role ?? "?", subrole: subrole).isSecure { return nil }
        let window = AXCaptureSource.element(root, "AXFocusedWindow") ?? AXCaptureSource.element(root, "AXMainWindow")
        let title = window.flatMap { AXCaptureSource.string($0, "AXTitle") }
        if CapturePrivacy().isPrivateWindow(app: captureApp, title: title) { return nil }
        guard let raw = AXCaptureSource.string(focused, "AXSelectedText") else { return nil }
        return FrontSelection.make(text: raw, appName: name, windowTitle: title)
    }

    private static func bare(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.hasPrefix("AX") ? String(text.dropFirst(2)) : text
    }
}
