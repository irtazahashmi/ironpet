import Foundation

/// An element the AX layer can act on. The service never looks inside it.
package typealias DesktopElement = AnyObject

package struct DesktopWindowInfo {
    package init(title: String? = nil, windowID: UInt32? = nil, focused: Bool, element: DesktopElement) {
        self.title = title
        self.windowID = windowID
        self.focused = focused
        self.element = element
    }

    package var title: String?
    /// The window server id, so a screenshot is of this window and no other.
    package var windowID: UInt32?
    package var focused: Bool
    package var element: DesktopElement
}

/// A live read of one window. `elements` lists the element behind every node of `root`, in pre-order.
package struct DesktopRead {
    package init(app: CaptureApp, window: DesktopWindowInfo, root: AXNode, elements: [DesktopElement]) {
        self.app = app
        self.window = window
        self.root = root
        self.elements = elements
    }

    package var app: CaptureApp
    package var window: DesktopWindowInfo
    package var root: AXNode
    package var elements: [DesktopElement]
}

/// The live accessibility calls the desktop tools need, behind a protocol so tests can drive the service with a synthetic tree.
package protocol DesktopAX: AnyObject {
    var isTrusted: Bool { get }
    var screenRecordingGranted: Bool { get }
    /// A running app by bundle id or name. An exact match wins over a partial one.
    func runningApp(matching query: String) -> CaptureApp?
    func windows(of app: CaptureApp) -> [DesktopWindowInfo]
    func read(app: CaptureApp, window: DesktopWindowInfo, budget: CaptureReadBudget) -> DesktopRead?
    /// The element's own fields, without children. Nil when the element is gone.
    func attributes(of element: DesktopElement) -> AXNode?
    func actions(of element: DesktopElement) -> [String]
    func perform(_ action: String, on element: DesktopElement) -> Bool
    func isSettable(_ attribute: String, on element: DesktopElement) -> Bool
    func set(_ attribute: String, to text: String, on element: DesktopElement) -> Bool
    /// Focuses the element, or raises it when it is a window.
    func focus(_ element: DesktopElement) -> Bool
    /// A PNG of the window, taken without writing a file. Nil when it cannot be captured.
    func screenshot(of window: DesktopWindowInfo, app: CaptureApp) -> Data?
    /// The element's children as the app lists them (AXChildren, or AXContents for a popup), live. Empty when it has none or is gone.
    func children(of element: DesktopElement) -> [DesktopElement]
    /// A boolean attribute such as AXSelected, AXDisclosing or AXExpanded. Nil when the element lacks it.
    func boolean(_ attribute: String, of element: DesktopElement) -> Bool?
    func setBoolean(_ attribute: String, to value: Bool, on element: DesktopElement) -> Bool
    func isFrontmost(_ app: CaptureApp) -> Bool
    /// Brings the app to the front.
    func activate(_ app: CaptureApp)
    /// The element that has the keyboard focus inside the app.
    func focusedElement(of app: CaptureApp) -> DesktopElement?
    /// Posts the key down and key up to the app's process only, never to the system-wide event stream. False when it could not post.
    func post(_ stroke: DesktopKeyStroke, to app: CaptureApp) -> Bool
}

/// Nothing is reachable. Test mode uses it, so an automated run never touches the real screen.
package final class IdleDesktopAX: DesktopAX {
    package init() {}

    package var isTrusted: Bool { false }
    package var screenRecordingGranted: Bool { false }
    package func runningApp(matching query: String) -> CaptureApp? { nil }
    package func windows(of app: CaptureApp) -> [DesktopWindowInfo] { [] }
    package func read(app: CaptureApp, window: DesktopWindowInfo, budget: CaptureReadBudget) -> DesktopRead? { nil }
    package func attributes(of element: DesktopElement) -> AXNode? { nil }
    package func actions(of element: DesktopElement) -> [String] { [] }
    package func perform(_ action: String, on element: DesktopElement) -> Bool { false }
    package func isSettable(_ attribute: String, on element: DesktopElement) -> Bool { false }
    package func set(_ attribute: String, to text: String, on element: DesktopElement) -> Bool { false }
    package func focus(_ element: DesktopElement) -> Bool { false }
    package func screenshot(of window: DesktopWindowInfo, app: CaptureApp) -> Data? { nil }
    package func children(of element: DesktopElement) -> [DesktopElement] { [] }
    package func boolean(_ attribute: String, of element: DesktopElement) -> Bool? { nil }
    package func setBoolean(_ attribute: String, to value: Bool, on element: DesktopElement) -> Bool { false }
    package func isFrontmost(_ app: CaptureApp) -> Bool { false }
    package func activate(_ app: CaptureApp) {}
    package func focusedElement(of app: CaptureApp) -> DesktopElement? { nil }
    package func post(_ stroke: DesktopKeyStroke, to app: CaptureApp) -> Bool { false }
}

/// What opening an address needs from the system, behind a protocol so tests can drive the service without a browser.
package protocol DesktopOpener: AnyObject {
    /// The bundle id of the frontmost app when it is a browser.
    func frontmostBrowser() -> String?
    /// A browser by bundle id or name, running or installed. Nil when none matches.
    func browser(matching query: String) -> (bundleId: String, name: String)?
    /// Opens the address in a new tab of the browser, or of the default browser when `bundleId` is nil.
    func open(_ url: URL, inBrowser bundleId: String?) -> Bool
}

package final class IdleDesktopOpener: DesktopOpener {
    package init() {}

    package func frontmostBrowser() -> String? { nil }
    package func browser(matching query: String) -> (bundleId: String, name: String)? { nil }
    package func open(_ url: URL, inBrowser bundleId: String?) -> Bool { false }
}
