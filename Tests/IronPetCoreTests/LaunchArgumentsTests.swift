import XCTest
@testable import IronPetCore

final class LaunchArgumentsTests: XCTestCase {
    private func route(_ args: String...) -> LaunchArguments.Route { LaunchArguments.route(["/Applications/IronPet.app/Contents/MacOS/IronPet"] + args) }

    func testNoArgumentsAndOptionsStartTheGUI() {
        XCTAssertEqual(route(), .gui)
        XCTAssertEqual(route("--test-mode"), .gui)
        XCTAssertEqual(route("-psn_0_12345"), .gui)
        XCTAssertEqual(route("--test-mode", "-chatDraft", ""), .gui)
    }

    func testUnknownSubcommandIsRejectedInsteadOfStartingTheGUI() {
        for command in ["bogus", "list", "dashboards"] {
            guard case .reject(let message) = route(command, "--label", "x") else { return XCTFail("\(command) started the GUI") }
            XCTAssertTrue(message.contains(command))
        }
    }

    func testRemovedTasksCommandPointsToInbox() {
        guard case .reject(let message) = route("tasks", "list", "--label", "merge=auto") else { return XCTFail("tasks started the GUI") }
        XCTAssertTrue(message.contains("inbox"))
    }

    func testUnknownLongOptionIsRejected() {
        XCTAssertEqual(route("--version"), .reject("ironpet: unknown option --version. It was not started."))
    }
}

final class SingleInstanceTests: XCTestCase {
    private func lockURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-lock-\(UUID().uuidString)/instance.lock") }

    func testSecondAcquireSeesTheFirstPid() {
        let url = lockURL()
        guard case .acquired(let first) = SingleInstance.acquire(at: url) else { return XCTFail("first should acquire") }
        guard case .running(let pid) = SingleInstance.acquire(at: url) else { return XCTFail("second should see the first") }
        XCTAssertEqual(pid, getpid())
        withExtendedLifetime(first) {}
    }

    func testLockIsFreeAfterTheHolderGoesAway() {
        let url = lockURL()
        var first: SingleInstance?
        if case .acquired(let held) = SingleInstance.acquire(at: url) { first = held }
        XCTAssertNotNil(first)
        first = nil
        guard case .acquired = SingleInstance.acquire(at: url) else { return XCTFail("a released lock must not block a relaunch") }
    }

    func testLockLeftByADeadProcessDoesNotBlock() throws {
        let url = lockURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "99999\n".write(to: url, atomically: true, encoding: .utf8) // a stale file, no live holder
        guard case .acquired = SingleInstance.acquire(at: url) else { return XCTFail("a stale file must not block") }
    }
}
