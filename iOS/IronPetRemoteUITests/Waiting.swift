import XCTest

extension XCUIElement {
    /// Waits for the element to exist, like `waitForExistence(timeout:)`, but returns at once when it is already there and polls every
    /// 0.5 s otherwise. `waitForExistence` always spends about a second on its first check, even for an element that is on screen.
    /// The timeout is an upper bound, so a present element costs nothing.
    @discardableResult
    func appears(timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { self.exists }
    }

    /// Waits for the element to go away, like `waitForNonExistence(timeout:)`, with the same quick first check and 0.5 s polling.
    @discardableResult
    func vanishes(timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { !self.exists }
    }

    private func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= deadline { return false }
            usleep(500_000)
        }
    }
}
