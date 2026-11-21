import AppKit
import ApplicationServices
import IronPetCore

/// The macOS implementation. It reads through `AXCaptureSource`, so the live tree has the same node and time budgets, the same
/// Chromium and Electron switch and the same secure field rule as screen capture.
final class LiveDesktopAX: DesktopAX {
    private final class Box { let element: AXUIElement; init(_ element: AXUIElement) { self.element = element } }

    private let source = AXCaptureSource()

    var isTrusted: Bool { AXIsProcessTrusted() }
    var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    func runningApp(matching query: String) -> CaptureApp? {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        func make(_ app: NSRunningApplication) -> CaptureApp {
            CaptureApp(bundleId: app.bundleIdentifier ?? "", name: app.localizedName ?? app.bundleIdentifier ?? "", pid: app.processIdentifier)
        }
        if let exact = apps.first(where: { $0.bundleIdentifier?.lowercased() == wanted || $0.localizedName?.lowercased() == wanted }) { return make(exact) }
        return apps.first { $0.localizedName?.lowercased().contains(wanted) == true }.map(make)
    }

    func windows(of app: CaptureApp) -> [DesktopWindowInfo] {
        guard isTrusted else { return [] }
        let root = source.appElement(for: app)
        let focused = AXCaptureSource.element(root, "AXFocusedWindow") ?? AXCaptureSource.element(root, "AXMainWindow")
        return AXCaptureSource.elements(root, "AXWindows").map { window in
            var id: CGWindowID = 0
            let windowID = _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
            let title = AXCaptureSource.string(window, "AXTitle").flatMap { $0.isEmpty ? nil : $0 }
            return DesktopWindowInfo(title: title, windowID: windowID, focused: focused.map { CFEqual($0, window) } ?? false, element: Box(window))
        }
    }

    func read(app: CaptureApp, window: DesktopWindowInfo, budget: CaptureReadBudget) -> DesktopRead? {
        guard let element = ax(window.element) else { return nil }
        let tracker = AXCaptureSource.Budget(budget, keepElements: true)
        guard let root = AXCaptureSource.convert(element, depth: 0, budget: tracker) else { return nil }
        return DesktopRead(app: app, window: window, root: root, elements: (tracker.elements ?? []).map { Box($0) })
    }

    func attributes(of element: DesktopElement) -> AXNode? {
        guard let el = ax(element) else { return nil }
        var head: CFArray?
        let names = ["AXRole", "AXSubrole", "AXTitle", "AXValue", "AXDescription"]
        guard AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &head) == .success,
              let values = head as? [AnyObject], values.count == names.count else { return nil }
        func get(_ index: Int) -> String? {
            let value = values[index]
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return AXCaptureSource.text(value)
        }
        guard let role = get(0) else { return nil }
        func bare(_ text: String) -> String { text.hasPrefix("AX") ? String(text.dropFirst(2)) : text }
        var node = AXNode(role: bare(role), subrole: get(1).map(bare))
        // A secure field is never read, here or anywhere.
        if node.isSecure { return node }
        node.title = get(2)
        node.value = get(3)
        node.description = get(4)
        return node
    }

    func actions(of element: DesktopElement) -> [String] {
        guard let el = ax(element) else { return [] }
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    func perform(_ action: String, on element: DesktopElement) -> Bool {
        guard let el = ax(element) else { return false }
        return AXUIElementPerformAction(el, action as CFString) == .success
    }

    func isSettable(_ attribute: String, on element: DesktopElement) -> Bool {
        guard let el = ax(element) else { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, attribute as CFString, &settable) == .success && settable.boolValue
    }

    func set(_ attribute: String, to text: String, on element: DesktopElement) -> Bool {
        guard let el = ax(element) else { return false }
        return AXUIElementSetAttributeValue(el, attribute as CFString, text as CFString) == .success
    }

    func focus(_ element: DesktopElement) -> Bool {
        guard let el = ax(element) else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, "AXRole" as CFString, &role)
        if role as? String == "AXWindow" {
            let raised = AXUIElementPerformAction(el, "AXRaise" as CFString) == .success
            let main = AXUIElementSetAttributeValue(el, "AXMain" as CFString, kCFBooleanTrue) == .success
            return raised || main
        }
        return AXUIElementSetAttributeValue(el, "AXFocused" as CFString, kCFBooleanTrue) == .success
    }

    func screenshot(of window: DesktopWindowInfo, app: CaptureApp) -> Data? {
        guard let id = window.windowID, let image = ScreenOCR.screenshot(ofWindow: id, ownedBy: app.pid) else { return nil }
        return NSBitmapImageRep(cgImage: Self.scaled(image, longEdge: 1_600)).representation(using: .png, properties: [:])
    }

    /// The image, smaller when its long edge is over `longEdge`, so a window picture stays a size an agent can take in.
    static func scaled(_ image: CGImage, longEdge: Int) -> CGImage {
        let long = max(image.width, image.height)
        guard long > longEdge else { return image }
        let factor = Double(longEdge) / Double(long)
        let width = max(1, Int(Double(image.width) * factor)), height = max(1, Int(Double(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    func children(of element: DesktopElement) -> [DesktopElement] {
        guard let el = ax(element) else { return [] }
        var list = AXCaptureSource.elements(el, "AXChildren")
        if list.isEmpty { list = AXCaptureSource.elements(el, "AXContents") }
        return list.map { Box($0) }
    }

    func boolean(_ attribute: String, of element: DesktopElement) -> Bool? {
        guard let el = ax(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success, let value else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) }
        return (value as? NSNumber)?.boolValue
    }

    func setBoolean(_ attribute: String, to value: Bool, on element: DesktopElement) -> Bool {
        guard let el = ax(element) else { return false }
        return AXUIElementSetAttributeValue(el, attribute as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef) == .success
    }

    func isFrontmost(_ app: CaptureApp) -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.pid }

    func activate(_ app: CaptureApp) {
        NSRunningApplication(processIdentifier: app.pid)?.activate()
        // Activation is asynchronous. A short wait lets the app take the keyboard focus before the keys arrive.
        Thread.sleep(forTimeInterval: 0.2)
    }

    func focusedElement(of app: CaptureApp) -> DesktopElement? {
        AXCaptureSource.element(source.appElement(for: app), "AXFocusedUIElement").map { Box($0) }
    }

    func post(_ stroke: DesktopKeyStroke, to app: CaptureApp) -> Bool {
        // A private source keeps the key state of the real keyboard out of the event. postToPid sends to this process only.
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(stroke.keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(stroke.keyCode), keyDown: false) else { return false }
        let flags = CGEventFlags(rawValue: stroke.flags.rawValue)
        down.flags = flags
        up.flags = flags
        down.postToPid(app.pid)
        Thread.sleep(forTimeInterval: 0.02)
        up.postToPid(app.pid)
        return true
    }

    private func ax(_ element: DesktopElement) -> AXUIElement? { (element as? Box)?.element }
}

final class LiveDesktopOpener: DesktopOpener {
    func frontmostBrowser() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier.flatMap { CaptureFloor.isBrowser($0) ? $0 : nil }
    }

    func browser(matching query: String) -> (bundleId: String, name: String)? {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        func name(_ bundleId: String, _ url: URL?) -> String {
            url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleId
        }
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> (String, String)? in
            guard let id = app.bundleIdentifier, CaptureFloor.isBrowser(id) else { return nil }
            return (id, app.localizedName ?? id)
        }
        if let hit = running.first(where: { $0.0.lowercased() == wanted || $0.1.lowercased() == wanted }) { return hit }
        // Not running: a known browser id that is installed, or an installed one whose name matches.
        let installed = CaptureFloor.browsers.compactMap { id -> (String, String)? in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { (id, name(id, $0)) }
        }
        return installed.first(where: { $0.0 == wanted || $0.1.lowercased() == wanted })
            ?? running.first(where: { $0.1.lowercased().contains(wanted) }) ?? installed.first(where: { $0.1.lowercased().contains(wanted) })
    }

    func open(_ url: URL, inBrowser bundleId: String?) -> Bool {
        guard let bundleId else { return NSWorkspace.shared.open(url) }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return false }
        let done = DispatchSemaphore(value: 0)
        var opened = false
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { running, error in
            opened = running != nil && error == nil
            done.signal()
        }
        return done.wait(timeout: .now() + 5) == .success && opened
    }
}
