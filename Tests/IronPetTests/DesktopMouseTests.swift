import XCTest
@testable import IronPet
@testable import IronPetCore

/// desktop_click and desktop_scroll against the synthetic app. The window sits left of the main display (negative x) so the
/// conversion from window-relative to screen points is tested where it could go wrong.
final class DesktopMouseTests: XCTestCase {
    var ax: FakeAX!
    var privacy: CapturePrivacy!
    var service: DesktopService!
    var approvals: [DesktopApproval] = []
    var answer = true
    var records: [DesktopActionRecord] = []

    let windowFrame = DesktopRect(x: -1000, y: 50, width: 800, height: 600)
    let save = FakeEl(AXNode(role: "Button", title: "Save"), actions: ["AXPress"])
    let delete = FakeEl(AXNode(role: "Button", title: "Delete"), actions: ["AXPress"])
    let secret = FakeEl(AXNode(role: "TextField", subrole: "SecureTextField", value: "hunter2"), settable: ["AXValue"])
    let list = FakeEl(AXNode(role: "List", description: "Items"))
    let offscreen = FakeEl(AXNode(role: "Button", title: "Far away"), actions: ["AXPress"])

    override func setUp() {
        super.setUp()
        save.frame = DesktopRect(x: -900, y: 100, width: 100, height: 40)
        delete.frame = DesktopRect(x: -700, y: 100, width: 100, height: 40)
        secret.frame = DesktopRect(x: -900, y: 200, width: 200, height: 30)
        list.frame = DesktopRect(x: -500, y: 300, width: 200, height: 200)
        offscreen.frame = DesktopRect(x: -900, y: 900, width: 100, height: 40)
        let window = FakeEl(AXNode(role: "Window", title: "Draft"), [save, delete, secret, list, offscreen])
        window.frame = windowFrame
        ax = FakeAX(window: window)
        privacy = CapturePrivacy()
        answer = true
        approvals = []
        records = []
        var deps = DesktopService.Dependencies(privacy: privacy)
        deps.ax = ax
        deps.enabled = { true }
        deps.approve = { [unowned self] request in approvals.append(request); return answer }
        deps.record = { [unowned self] record in records.append(record) }
        service = DesktopService(deps)
    }

    private func value(_ name: String, _ args: [String: Any], file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        switch await service.call(name, args) {
        case .success(.value(let value)): return try XCTUnwrap(value as? [String: Any], file: file, line: line)
        case .success: XCTFail("expected a value", file: file, line: line); return [:]
        case .failure(let failure): XCTFail(failure.message, file: file, line: line); return [:]
        }
    }

    private func failure(_ name: String, _ args: [String: Any], file: StaticString = #filePath, line: UInt = #line) async -> String {
        switch await service.call(name, args) {
        case .failure(let failure): return failure.message
        case .success: XCTFail("expected a failure", file: file, line: line); return ""
        }
    }

    private func ref(_ title: String) async throws -> String {
        let out = try await value("desktop_find", ["app": "Notes", "name": title])
        let line = try XCTUnwrap((out["elements"] as? String)?.split(separator: "\n").first)
        return String(try XCTUnwrap(line.split(separator: " ").last))
    }

    private func snapshotRef(role: String) async throws -> String {
        let out = try await value("desktop_snapshot", ["app": "Notes", "role": role])
        let line = try XCTUnwrap((out["elements_found"] as? String)?.split(separator: "\n").first)
        return String(try XCTUnwrap(line.split(separator: " ").last))
    }

    private var presses: [(DesktopMouseEvent, Int32)] { ax.mouseEvents.filter { $0.0.phase != .move } }

    // MARK: S1

    func testClickByRefPostsOneDownAndUpAtTheCentreForTheAppsProcess() async throws {
        ax.hitTest = { [save] _ in save }
        let out = try await value("desktop_click", ["ref": try await ref("Save")])
        let centre = DesktopPoint(x: -850, y: 120)
        XCTAssertEqual(presses.map(\.0.phase), [.down, .up])
        XCTAssertEqual(presses.map(\.0.point), [centre, centre])
        XCTAssertEqual(presses.map(\.1), [4242, 4242])
        XCTAssertEqual(presses.map(\.0.button), [.left, .left])
        XCTAssertEqual(presses.map(\.0.clickState), [1, 1])
        XCTAssertEqual(out["cursor_moved"] as? Bool, false)
        XCTAssertEqual((out["screen_point"] as? [String: Double])?["x"], -850)
        XCTAssertEqual(out["element"] as? String, "button \"Save\"")
        XCTAssertEqual(records.last?.action, "click")
        XCTAssertEqual(records.last?.outcome, .done)
        XCTAssertTrue(approvals.isEmpty)
    }

    func testAStaleRefAndAnElementOutsideTheWindowPostNothing() async throws {
        let far = try await ref("Far away")
        let outside = await failure("desktop_click", ["ref": far])
        XCTAssertTrue(outside.contains("outside the window"), outside)
        let stale = await failure("desktop_click", ["ref": "#doesnotexist"])
        XCTAssertTrue(stale.contains("not known"), stale)
        XCTAssertTrue(ax.mouseEvents.isEmpty)
        XCTAssertEqual(records.last?.outcome, .refused)
    }

    func testAnElementWithoutAFrameCannotBeClickedByRef() async throws {
        let target = try await ref("Save")
        save.frame = nil
        let message = await failure("desktop_click", ["ref": target])
        XCTAssertTrue(message.contains("no position"), message)
        XCTAssertTrue(ax.mouseEvents.isEmpty)
    }

    func testAnAppInTheBackgroundIsRaisedBeforeTheClick() async throws {
        ax.frontmost = false
        _ = try await value("desktop_click", ["ref": try await ref("Save")])
        XCTAssertEqual(ax.activated, ["Notes"])
        XCTAssertEqual(presses.count, 2)
    }

    func testTheResultSaysWhenTheRealPointerMoved() async throws {
        ax.cursorMoves = true
        let out = try await value("desktop_click", ["ref": try await ref("Save")])
        XCTAssertEqual(out["cursor_moved"] as? Bool, true)
        XCTAssertTrue((out["note"] as? String ?? "").contains("pointer moved"), "\(out)")
    }

    func testAPostThatFailsIsReportedAndLogged() async throws {
        ax.postWorks = false
        let message = await failure("desktop_click", ["ref": try await ref("Save")])
        XCTAssertTrue(message.contains("could not be posted"), message)
        XCTAssertEqual(records.last?.outcome, .failed)
    }

    // MARK: S2

    func testAPointIsConvertedFromTheWindowToTheScreen() async throws {
        let out = try await value("desktop_click", ["app": "Notes", "x": 100, "y": 20.5])
        XCTAssertEqual(presses.map(\.0.point), [DesktopPoint(x: -900, y: 70.5), DesktopPoint(x: -900, y: 70.5)])
        XCTAssertEqual(out["element"] as? String, "none found under the point")
        XCTAssertTrue((out["note"] as? String ?? "").contains("No element was found"), "\(out)")
    }

    func testAPointOutsideTheWindowIsRefusedWithAMessage() async throws {
        for (x, y) in [(-1.0, 10.0), (10.0, -1.0), (800.0, 10.0), (10.0, 600.0), (5000.0, 5000.0)] {
            let message = await failure("desktop_click", ["app": "Notes", "x": x, "y": y])
            XCTAssertTrue(message.contains("outside the window") && message.contains("800 by 600"), message)
        }
        XCTAssertTrue(ax.mouseEvents.isEmpty)
    }

    func testAPointClickNeedsBothCoordinates() async throws {
        let onlyX = await failure("desktop_click", ["app": "Notes", "x": 5])
        XCTAssertTrue(onlyX.contains("x and y are required"), onlyX)
        let nothing = await failure("desktop_click", [:])
        XCTAssertTrue(nothing.contains("ref"), nothing)
        let both = await failure("desktop_click", ["ref": "#abcdef", "app": "Notes", "x": 1, "y": 1])
        XCTAssertTrue(both.contains("not both"), both)
    }

    // MARK: S3

    func testRightButtonDoubleClickAndModifiersAreCarriedOnTheEvents() async throws {
        let target = try await ref("Save")
        _ = try await value("desktop_click", ["ref": target, "button": "right", "count": 2, "modifiers": ["cmd", "shift"]])
        XCTAssertEqual(presses.map(\.0.phase), [.down, .up, .down, .up])
        XCTAssertEqual(presses.map(\.0.clickState), [1, 1, 2, 2])
        XCTAssertTrue(presses.allSatisfy { $0.0.button == .right })
        XCTAssertTrue(presses.allSatisfy { $0.0.flags == [.maskCommand, .maskShift] })
        XCTAssertEqual(records.last?.action, "cmd+shift+double right click")
    }

    func testModifiersMayBeOneString() async throws {
        _ = try await value("desktop_click", ["ref": try await ref("Save"), "modifiers": "ctrl+opt"])
        XCTAssertTrue(presses.allSatisfy { $0.0.flags == [.maskControl, .maskAlternate] })
    }

    func testUnknownButtonModifierAndCountNameTheValidValues() async throws {
        let target = try await ref("Save")
        let button = await failure("desktop_click", ["ref": target, "button": "middle"])
        XCTAssertTrue(button.contains("left or right"), button)
        let modifier = await failure("desktop_click", ["ref": target, "modifiers": ["hyper"]])
        XCTAssertTrue(modifier.contains("cmd, shift, opt or ctrl"), modifier)
        let count = await failure("desktop_click", ["ref": target, "count": 3])
        XCTAssertTrue(count.contains("1") && count.contains("2"), count)
        let fraction = await failure("desktop_click", ["ref": target, "count": 1.5])
        XCTAssertTrue(fraction.contains("1 or 2"), fraction)
        XCTAssertTrue(ax.mouseEvents.isEmpty)
    }

    // MARK: S4

    func testClickingDeleteAsksFirstAndPostsNothingWhenDeclined() async throws {
        answer = false
        let target = try await ref("Delete")
        let message = await failure("desktop_click", ["ref": target])
        XCTAssertEqual(message, "the user declined this action.")
        XCTAssertEqual(approvals.count, 1)
        XCTAssertTrue(approvals[0].title.contains("click") && approvals[0].title.contains("Delete"), approvals[0].title)
        XCTAssertTrue(ax.mouseEvents.isEmpty)
        XCTAssertEqual(records.last?.outcome, .declined)
    }

    func testApprovingDeleteClicksAfterCheckingTheElementAgain() async throws {
        let target = try await ref("Delete")
        _ = try await value("desktop_click", ["ref": target])
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(presses.count, 2)
        XCTAssertEqual(records.last?.outcome, .done)
    }

    func testTheElementIsCheckedAgainAfterTheAnswer() async throws {
        let target = try await ref("Delete")
        // The user takes a moment, and the button turns into another one.
        service = makeService(approve: { [unowned self] request in
            approvals.append(request)
            delete.node.title = "Archive"
            return true
        })
        let message = await failure("desktop_click", ["ref": target])
        XCTAssertTrue(message.contains("not known or its element changed"), message)
        XCTAssertTrue(ax.mouseEvents.isEmpty)
    }

    func testAPointOverADeleteButtonAsks() async throws {
        ax.hitTest = { [delete] _ in delete }
        answer = false
        let message = await failure("desktop_click", ["app": "Notes", "x": 300, "y": 70])
        XCTAssertEqual(message, "the user declined this action.")
        XCTAssertEqual(approvals.count, 1)
        XCTAssertTrue(ax.mouseEvents.isEmpty)
        answer = true
        _ = try await value("desktop_click", ["app": "Notes", "x": 300, "y": 70])
        XCTAssertEqual(approvals.count, 2)
        XCTAssertEqual(presses.count, 2)
    }

    func testAWindowTitleThatSaysSendAsksForAPointClick() async throws {
        ax.windowTitle = "Send payment"
        ax.window.node.title = "Send payment"
        answer = false
        let message = await failure("desktop_click", ["app": "Notes", "x": 10, "y": 10])
        XCTAssertEqual(message, "the user declined this action.")
        XCTAssertTrue(approvals.first?.detail.contains("window title") ?? false, "\(approvals)")
    }

    // MARK: S5

    func testAPasswordFieldIsNeverClickedByRefOrByPoint() async throws {
        let byRef = await failure("desktop_click", ["ref": try await snapshotRef(role: "textfield")])
        XCTAssertTrue(byRef.contains("password field"), byRef)
        ax.hitTest = { [secret] _ in secret }
        let byPoint = await failure("desktop_click", ["app": "Notes", "x": 100, "y": 160])
        XCTAssertTrue(byPoint.contains("password field"), byPoint)
        let scroll = await failure("desktop_scroll", ["app": "Notes", "x": 100, "y": 160, "direction": "down"])
        XCTAssertTrue(scroll.contains("password field"), scroll)
        XCTAssertTrue(ax.mouseEvents.isEmpty && ax.scrolls.isEmpty)
        XCTAssertEqual(records.last?.outcome, .refused)
    }

    func testAPasswordManagerAndAPrivateWindowRefuseClicksAndScrolls() async throws {
        let target = try await ref("Save")
        ax.app = CaptureApp(bundleId: "com.example.1password", name: "Vault", pid: 9)
        for (name, args) in [("desktop_click", ["app": "Vault", "x": 5, "y": 5] as [String: Any]), ("desktop_scroll", ["app": "Vault", "direction": "down"])] {
            let message = await failure(name, args)
            XCTAssertTrue(message.contains("deny list"), message)
        }
        ax.app = CaptureApp(bundleId: "com.apple.Safari", name: "Browser", pid: 5)
        ax.windowTitle = "Reading — Private Browsing"
        for (name, args) in [("desktop_click", ["app": "Browser", "x": 5, "y": 5] as [String: Any]), ("desktop_scroll", ["app": "Browser", "direction": "down"])] {
            let message = await failure(name, args)
            XCTAssertTrue(message.contains("private browser window"), message)
        }
        // A ref taken before the app turned private is refused as well.
        ax.app = CaptureApp(bundleId: "com.example.notes", name: "Notes", pid: 4242)
        ax.windowTitle = "Draft"
        privacy.setExcluded(["Notes"])
        let denied = await failure("desktop_click", ["ref": target])
        XCTAssertTrue(denied.contains("does not read or act on Notes"), denied)
        XCTAssertTrue(ax.mouseEvents.isEmpty && ax.scrolls.isEmpty)
    }

    // MARK: S6

    func testScrollByRefPostsWheelEventsOverTheCentre() async throws {
        let out = try await value("desktop_scroll", ["ref": try snapshotRef(role: "list"), "direction": "down", "amount": 7])
        XCTAssertEqual(ax.scrolls.count, 1)
        XCTAssertEqual(ax.scrolls[0].direction, .down)
        XCTAssertEqual(ax.scrolls[0].lines, 7)
        XCTAssertEqual(ax.scrolls[0].point, DesktopPoint(x: -400, y: 400))
        XCTAssertEqual(ax.scrolls[0].pid, 4242)
        XCTAssertTrue((out["note"] as? String ?? "").contains("new desktop_snapshot"), "\(out)")
        XCTAssertTrue(approvals.isEmpty)
        XCTAssertEqual(records.last?.action, "scroll down 7")
        XCTAssertEqual(records.last?.outcome, .done)
    }

    func testScrollWithoutAPointUsesTheWindowCentreAndTheDefaultAndCapAmounts() async throws {
        _ = try await value("desktop_scroll", ["app": "Notes", "direction": "up"])
        _ = try await value("desktop_scroll", ["app": "Notes", "direction": "left", "amount": 500])
        _ = try await value("desktop_scroll", ["app": "Notes", "direction": "right", "amount": 0, "x": 10, "y": 20])
        XCTAssertEqual(ax.scrolls.map(\.lines), [3, 20, 1])
        XCTAssertEqual(ax.scrolls.map(\.direction), [.up, .left, .right])
        XCTAssertEqual(ax.scrolls[0].point, DesktopPoint(x: -600, y: 350))
        XCTAssertEqual(ax.scrolls[2].point, DesktopPoint(x: -990, y: 70))
    }

    func testHugeNumbersDoNotCrashAndAreClamped() async throws {
        _ = try await value("desktop_scroll", ["app": "Notes", "direction": "down", "amount": 1e30])
        XCTAssertEqual(ax.scrolls.map(\.lines), [20])
        let count = await failure("desktop_click", ["app": "Notes", "x": 10, "y": 20, "count": 1e30])
        XCTAssertTrue(count.contains("Use 1"), count)
    }

    func testScrollRefusesABadDirectionAndAPointOutsideTheWindow() async throws {
        let direction = await failure("desktop_scroll", ["app": "Notes", "direction": "sideways"])
        XCTAssertTrue(direction.contains("up, down, left or right"), direction)
        let missing = await failure("desktop_scroll", ["app": "Notes"])
        XCTAssertTrue(missing.contains("direction is required"), missing)
        let outside = await failure("desktop_scroll", ["app": "Notes", "direction": "down", "x": 9999, "y": 1])
        XCTAssertTrue(outside.contains("outside the window"), outside)
        XCTAssertTrue(ax.scrolls.isEmpty)
    }

    func testScrollOverADeleteButtonDoesNotAsk() async throws {
        ax.hitTest = { [delete] _ in delete }
        _ = try await value("desktop_scroll", ["app": "Notes", "x": 300, "y": 70, "direction": "down"])
        XCTAssertTrue(approvals.isEmpty)
        XCTAssertEqual(ax.scrolls.count, 1)
    }

    // MARK: Plumbing

    func testClickAndScrollAreOffWhenDesktopControlIsOff() async throws {
        var deps = DesktopService.Dependencies(privacy: privacy)
        deps.ax = ax
        let off = DesktopService(deps)
        for name in ["desktop_click", "desktop_scroll"] {
            switch await off.call(name, ["app": "Notes", "x": 1, "y": 1, "direction": "down"]) {
            case .failure(let failure): XCTAssertTrue(failure.message.contains("off"), failure.message)
            case .success: XCTFail("expected a failure")
            }
        }
    }

    func testTheToolsAreListedWithTheirSchemas() {
        let tools = DesktopMCP.tools.reduce(into: [String: [String: Any]]()) { $0[$1["name"] as? String ?? ""] = $1 }
        let click = (tools["desktop_click"]?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        XCTAssertEqual(Set(click?.keys.map { $0 } ?? []), ["ref", "app", "window", "x", "y", "button", "count", "modifiers"])
        let scroll = tools["desktop_scroll"]?["inputSchema"] as? [String: Any]
        XCTAssertEqual(scroll?["required"] as? [String], ["direction"])
    }

    func testTheGeometryHelpersHandleNegativeAndFractionalOrigins() {
        let frame = DesktopRect(x: -1920.5, y: -200, width: 1000, height: 500)
        XCTAssertEqual(frame.center, DesktopPoint(x: -1420.5, y: 50))
        XCTAssertEqual(frame.screenPoint(x: 10, y: 20), DesktopPoint(x: -1910.5, y: -180))
        XCTAssertTrue(frame.contains(DesktopPoint(x: -1920.5, y: -200)))
        XCTAssertFalse(frame.contains(DesktopPoint(x: -920.5, y: -200)))
        XCTAssertEqual(DesktopMouse.events(button: .left, count: 1, flags: [], at: frame.center).map(\.phase), [.move, .down, .up])
        XCTAssertEqual(DesktopMouse.scrollLines(nil), 3)
        XCTAssertEqual(DesktopMouse.scrollLines(100), 20)
        XCTAssertEqual(DesktopMouse.label(button: .left, count: 1, modifiers: []), "click")
    }

    private func makeService(approve: @escaping (DesktopApproval) async -> Bool) -> DesktopService {
        var deps = DesktopService.Dependencies(privacy: privacy)
        deps.ax = ax
        deps.enabled = { true }
        deps.approve = approve
        deps.record = { [unowned self] record in records.append(record) }
        return DesktopService(deps)
    }
}
