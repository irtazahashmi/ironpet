import AppKit
import IronPetCore

/// The Mac adapter for `URLOpener`: `NSWorkspace` opens the address in the default app. A failure to open is not reported, as before.
struct MacURLOpener: URLOpener {
    init() {}

    func open(_ url: URL) throws { NSWorkspace.shared.open(url) }
}
