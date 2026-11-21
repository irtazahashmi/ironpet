import Foundation

/// The app a window belongs to.
package struct CaptureApp: Equatable, Sendable {
    package init(bundleId: String, name: String, pid: pid_t = 0) {
        self.bundleId = bundleId
        self.name = name
        self.pid = pid
    }

    package var bundleId: String
    package var name: String
    package var pid: pid_t = 0
}

/// Why a capture was taken. Stored with the capture, so a reader can tell a typing pause from the idle timer.
package enum CaptureTrigger: String, Sendable {
    case appSwitch = "app_switch"
    case windowFocus = "window_focus"
    case typingPause = "typing_pause"
    case scrollStop = "scroll_stop"
    case click
    case idle
}

/// What happened on the Mac that may be worth a capture. Key events carry no key: only the fact that one was pressed.
package enum CaptureSignal: Equatable, Sendable {
    case appSwitch
    case windowFocus
    case key
    case scroll
    case click
}

/// One accessibility element, reduced to what text extraction needs. Roles have the `AX` prefix removed.
package struct AXNode: Equatable, Sendable {
    package var role: String
    package var subrole: String?
    package var title: String?
    package var value: String?
    package var description: String?
    /// For a web area: the page address.
    package var url: String?
    /// The element's id in the page (`AXDOMIdentifier`), when a web view has one. Stable across captures.
    package var domId: String?
    package var hidden = false
    package var children: [AXNode] = []
    /// The subtree hash `CaptureTree` gave this node. Empty for a node that came straight from the source.
    package var ref = ""

    package init(role: String, subrole: String? = nil, title: String? = nil, value: String? = nil, description: String? = nil, url: String? = nil,
         domId: String? = nil, hidden: Bool = false, children: [AXNode] = []) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.description = description
        self.url = url
        self.domId = domId
        self.hidden = hidden
        self.children = children
    }

    /// A password field. Its value is never read, here or by the source.
    package var isSecure: Bool { subrole == "SecureTextField" || role == "SecureTextField" }

    /// What the app calls this element: its title, else its description.
    package var name: String? {
        for text in [title, description] { if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text } }
        return nil
    }
}

/// The focused window of an app as the source read it.
package struct WindowRead: Equatable, Sendable {
    package init(app: CaptureApp, title: String? = nil, url: String? = nil, root: AXNode, windowID: UInt32? = nil) {
        self.app = app
        self.title = title
        self.url = url
        self.root = root
        self.windowID = windowID
    }

    package var app: CaptureApp
    package var title: String?
    /// The page address of a web view in the window, when there is one.
    package var url: String?
    package var root: AXNode
    /// The window server id of the window that was read, so a screenshot is of that window and no other. Nil when it is unknown.
    package var windowID: UInt32? = nil
}

/// What the source may spend on one window read.
package struct CaptureReadBudget: Equatable, Sendable {
    package init(maxNodes: Int = 6_000, maxTime: Double = 0.2) {
        self.maxNodes = maxNodes
        self.maxTime = maxTime
    }

    package var maxNodes = 6_000
    /// Seconds. An Electron tree can be huge, so the read takes what it got.
    package var maxTime = 0.2
}

/// The macOS side of capture, behind a protocol so tests can drive the service with a synthetic tree and a fake clock.
package protocol CaptureSource: AnyObject {
    /// Starts reporting signals. The callback may run on any thread.
    func start(onSignal: @escaping (CaptureSignal) -> Void)
    func stop()
    var isTrusted: Bool { get }
    func frontmostApp() -> CaptureApp?
    /// Reads the focused window's accessibility tree. Nil when there is no window or no access.
    func readFocusedWindow(of app: CaptureApp, budget: CaptureReadBudget) -> WindowRead?
    /// Lines of text from a screenshot of the window `windowID` (the one `readFocusedWindow` returned), read on this Mac. The image is
    /// never written to disk. Nil when Screen Recording is not allowed, the id is unknown or that window is gone.
    func recognizeFocusedWindow(of app: CaptureApp, windowID: UInt32?) -> [String]?
}

/// One capture's text, as stored and as the MCP tools return it.
package struct StoredCapture: Equatable, Identifiable, Sendable {
    package init(
        id: Int64,
        at: Date,
        app: String,
        appName: String,
        window: String,
        url: String? = nil,
        trigger: String,
        text: String,
        root: String? = nil
    ) {
        self.id = id
        self.at = at
        self.app = app
        self.appName = appName
        self.window = window
        self.url = url
        self.trigger = trigger
        self.text = text
        self.root = root
    }

    package var id: Int64
    package var at: Date
    package var app: String
    package var appName: String
    package var window: String
    package var url: String?
    package var trigger: String
    package var text: String
    /// The root hash of the stored accessibility tree. Nil for a capture of text only.
    package var root: String? = nil
}

/// A search result: the capture without its whole text.
package struct CaptureHit: Equatable, Identifiable, Sendable {
    package init(id: Int64, at: Date, app: String, appName: String, window: String, url: String? = nil, snippet: String) {
        self.id = id
        self.at = at
        self.app = app
        self.appName = appName
        self.window = window
        self.url = url
        self.snippet = snippet
    }

    package var id: Int64
    package var at: Date
    package var app: String
    package var appName: String
    package var window: String
    package var url: String?
    package var snippet: String
}
