import AppKit
import Carbon
import XCTest
@testable import IronPet

final class FnDictationTests: XCTestCase {
    // MARK: S1, S2

    func testSectionKeyWithModifierAndAloneAreAccepted() throws {
        let withCommand = try XCTUnwrap(Shortcut(keyCode: kVK_ISO_Section, modifierFlags: .command))
        XCTAssertEqual(withCommand.text, "cmd+section")
        XCTAssertEqual(Shortcut("cmd+section"), withCommand)
        XCTAssertEqual(withCommand.display, "⌘§")

        let alone = try XCTUnwrap(Shortcut(keyCode: kVK_ISO_Section, modifierFlags: []))
        XCTAssertEqual(alone.text, "section")
        XCTAssertEqual(Shortcut("section"), alone)
        XCTAssertEqual(alone.display, "§")
    }

    func testOtherKeysStillNeedAModifier() {
        XCTAssertNil(Shortcut(keyCode: kVK_JIS_Yen, modifierFlags: []))
        XCTAssertNotNil(Shortcut(keyCode: kVK_JIS_Yen, modifierFlags: .control))
        XCTAssertNil(Shortcut("yen"))
        XCTAssertEqual(Shortcut("ctrl+yen")?.display, "⌃¥")
    }

    func testUnknownKeyMessageNamesTheKeyNotTheModifierHint() throws {
        let unknown = kVK_Help
        let message = try XCTUnwrap(Shortcut.rejection(keyCode: unknown, modifierFlags: .command))
        XCTAssertTrue(message.contains("isn't supported"), message)
        XCTAssertFalse(message.contains("Use ⌘"), message)
    }

    func testKnownKeyWithoutModifierKeepsTheModifierHint() throws {
        let message = try XCTUnwrap(Shortcut.rejection(keyCode: kVK_ANSI_G, modifierFlags: .shift))
        XCTAssertTrue(message.hasPrefix("Use ⌘, ⌥ or ⌃"), message)
        XCTAssertNil(Shortcut.rejection(keyCode: kVK_ISO_Section, modifierFlags: []))
    }

    // MARK: S3

    private var time: TimeInterval = 0
    private var recording = false

    private func detector() -> FnKeyDetector {
        time = 0
        recording = false
        return FnKeyDetector(now: { [unowned self] in time }, isRecording: { [unowned self] in recording })
    }

    /// Applies an action the way the controller would.
    private func apply(_ action: FnKeyDetector.Action?) {
        switch action {
        case .start: recording = true
        case .stop, .cancel: recording = false
        case nil: break
        }
    }

    private func send(_ event: FnKeyDetector.Event, to detector: FnKeyDetector, after delay: TimeInterval = 0) -> FnKeyDetector.Action? {
        time += delay
        let action = detector.handle(event)
        apply(action)
        return action
    }

    func testHoldStartsOnDownAndStopsOnUp() {
        let d = detector()
        XCTAssertEqual(send(.fnDown, to: d), .start)
        XCTAssertEqual(send(.fnUp, to: d, after: FnKeyDetector.tapThreshold + 0.5), .stop)
        XCTAssertFalse(recording)
    }

    func testQuickTapTogglesOnAndSecondTapTogglesOff() {
        let d = detector()
        XCTAssertEqual(send(.fnDown, to: d), .start)
        XCTAssertNil(send(.fnUp, to: d, after: 0.1), "a tap leaves recording on")
        XCTAssertTrue(recording)
        XCTAssertEqual(send(.fnDown, to: d, after: 2), .stop)
        XCTAssertNil(send(.fnUp, to: d, after: 0.5), "the release after the stopping press does nothing")
        XCTAssertFalse(recording)
    }

    func testFnWithAnotherKeyCancelsAndTriggersNothingOnRelease() {
        let d = detector()
        XCTAssertEqual(send(.fnDown, to: d), .start)
        XCTAssertEqual(send(.otherKeyDown, to: d, after: 0.05), .cancel)
        XCTAssertNil(send(.fnUp, to: d, after: 1))
        XCTAssertFalse(recording)
    }

    func testReleaseAfterRecordingWasCancelledElsewhereDoesNotRestart() {
        let d = detector()
        XCTAssertEqual(send(.fnDown, to: d), .start)
        recording = false // Esc cancelled it while Fn is held.
        XCTAssertNil(send(.fnUp, to: d, after: 2))
        XCTAssertFalse(recording)
    }

    func testOtherKeyWithoutFnIsIgnored() {
        let d = detector()
        XCTAssertNil(send(.otherKeyDown, to: d))
        XCTAssertNil(send(.fnUp, to: d))
    }

    func testRepeatedDownDoesNotStartTwice() {
        let d = detector()
        XCTAssertEqual(send(.fnDown, to: d), .start)
        XCTAssertNil(send(.fnDown, to: d, after: 0.1))
    }

    // MARK: S4

    private final class FakeAccess: InputMonitoringAccess {
        var requests = 0
        var granted = true
        func request() -> Bool { requests += 1; return granted }
    }

    private final class FakeSource: FnEventSource {
        var onEvent: ((FnKeyDetector.Event) -> Void)?
        var installs = 0
        var removals = 0
        func install() -> Bool { installs += 1; return true }
        func remove() { removals += 1 }
    }

    private func trigger(access: FakeAccess, source: FakeSource, actions: @escaping (FnKeyDetector.Action) -> Void) -> FnDictationTrigger {
        FnDictationTrigger(access: access, source: source, detector: detector(), perform: actions)
    }

    func testNothingIsInstalledOrRequestedUnlessFnIsChosen() {
        let (access, source) = (FakeAccess(), FakeSource())
        var actions: [FnKeyDetector.Action] = []
        let t = trigger(access: access, source: source) { actions.append($0) }
        for shortcut in [nil, "", "ctrl+opt+space", "section", "f5"] { t.update(shortcut: shortcut) }
        XCTAssertEqual(access.requests, 0)
        XCTAssertEqual(source.installs, 0)
        XCTAssertFalse(t.isInstalled)
        source.onEvent?(.fnDown)
        source.onEvent?(.fnUp)
        // Without installing, the source delivers no events, so nothing was started by a stray Fn.
        XCTAssertEqual(access.requests, 0)
    }

    func testChoosingFnRequestsOnceAndInstallsThenRemovesWhenChangedAway() {
        let (access, source) = (FakeAccess(), FakeSource())
        var actions: [FnKeyDetector.Action] = []
        let t = trigger(access: access, source: source) { actions.append($0) }
        t.update(shortcut: "fn")
        t.update(shortcut: "fn")
        XCTAssertEqual(access.requests, 1)
        XCTAssertEqual(source.installs, 1)
        source.onEvent?(.fnDown)
        XCTAssertEqual(actions, [.start])
        t.update(shortcut: "ctrl+opt+space")
        XCTAssertEqual(source.removals, 1)
        XCTAssertFalse(t.isInstalled)
    }

    func testDeniedPermissionInstallsNothing() {
        let (access, source) = (FakeAccess(), FakeSource())
        access.granted = false
        let t = trigger(access: access, source: source) { _ in }
        t.update(shortcut: "fn")
        XCTAssertEqual(access.requests, 1)
        XCTAssertEqual(source.installs, 0)
        XCTAssertFalse(t.isInstalled)
    }
}
