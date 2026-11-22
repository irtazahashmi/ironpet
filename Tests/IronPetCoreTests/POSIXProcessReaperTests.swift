import XCTest
@testable import IronPetCore

final class POSIXProcessReaperTests: XCTestCase {
    /// Blocks every worker the global queue will give us until `release` is signalled.
    private func saturateGlobalPool(_ release: DispatchSemaphore) {
        for _ in 0..<(ProcessInfo.processInfo.activeProcessorCount * 4 + 64) {
            DispatchQueue.global().async { release.wait() }
        }
    }

    func testChildIsReapedWhileTheGlobalPoolIsSaturated() throws {
        let release = DispatchSemaphore(value: 0)
        saturateGlobalPool(release)
        defer { for _ in 0..<1024 { release.signal() } }

        let process = try POSIXProcessSpawner().spawn(ProcessSpec(executable: "/bin/echo", arguments: ["hi"]))
        let handled = expectation(description: "whenExited handler fires")
        process.whenExited { exit in
            XCTAssertEqual(exit, .code(0))
            handled.fulfill()
        }
        wait(for: [handled], timeout: 10)
        process.waitUntilExit()
        XCTAssertEqual(process.exit, .code(0))
    }

    func testLiveChildrenDoNotHoldGlobalWorkers() throws {
        var children: [RunningProcess] = []
        defer {
            children.forEach { $0.terminate() }
            children.forEach { $0.waitUntilExit() }
        }
        for _ in 0..<100 {
            children.append(try POSIXProcessSpawner().spawn(ProcessSpec(executable: "/bin/sleep", arguments: ["30"])))
        }
        let ran = expectation(description: "a global block still runs")
        DispatchQueue.global().async { ran.fulfill() }
        wait(for: [ran], timeout: 5)
        XCTAssertTrue(children.allSatisfy { $0.isRunning })
    }

    func testTerminateStillEndsTheProcessGroup() throws {
        let process = try POSIXProcessSpawner().spawn(ProcessSpec(executable: "/bin/sleep", arguments: ["30"]))
        process.terminate()
        process.waitUntilExit()
        XCTAssertEqual(process.exit, .signal(SIGTERM))
    }
}
