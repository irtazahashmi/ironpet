import XCTest
@testable import IronPet
@testable import IronPetCore

/// The same checks run against every adapter of a protocol that can run in `swift test`.
enum SecretStoreSuite {
    static func run(_ store: SecretStore, service: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let account = "conformance"
        try store.delete(service: service, account: account)
        XCTAssertNil(try store.get(service: service, account: account), "a missing secret reads as nil", file: file, line: line)
        try store.set(Data("first".utf8), service: service, account: account)
        XCTAssertEqual(try store.get(service: service, account: account), Data("first".utf8), file: file, line: line)
        try store.set(Data("second".utf8), service: service, account: account)
        XCTAssertEqual(try store.get(service: service, account: account), Data("second".utf8), "set overwrites", file: file, line: line)
        XCTAssertNil(try store.get(service: service, account: "other"), "accounts are separate", file: file, line: line)
        XCTAssertNil(try store.get(service: service + ".other", account: account), "services are separate", file: file, line: line)
        try store.delete(service: service, account: account)
        XCTAssertNil(try store.get(service: service, account: account), file: file, line: line)
        XCTAssertNoThrow(try store.delete(service: service, account: account), "deleting a missing secret is not an error", file: file, line: line)
    }
}

final class SecretStoreConformanceTests: XCTestCase {
    func testInMemoryStore() throws {
        try SecretStoreSuite.run(InMemorySecretStore(), service: "ironpet.test.memory")
    }

    /// Runs against the real Keychain with a service name of its own, and removes it afterwards. Skipped on CI, where the
    /// Keychain may be locked or may ask for approval, and when this process cannot reach the Keychain.
    func testKeychainStore() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "the Keychain may be locked or prompt on CI")
        let store = KeychainSecretStore()
        let service = "ironpet.test.\(UUID().uuidString)"
        do {
            try store.set(Data("probe".utf8), service: service, account: "probe")
        } catch {
            throw XCTSkip("the Keychain is not reachable in the test process: \(error.localizedDescription)")
        }
        defer {
            try? store.delete(service: service, account: "probe")
            try? store.delete(service: service, account: "conformance")
            try? store.delete(service: service + ".other", account: "conformance")
        }
        try SecretStoreSuite.run(store, service: service)
    }

    func testTextHelpersTrimAndTreatBlankAsRemoval() {
        let store = InMemorySecretStore()
        XCTAssertTrue(store.save(text: "  key \n", service: "s", account: "a"))
        XCTAssertEqual(store.text(service: "s", account: "a"), "key")
        XCTAssertTrue(store.save(text: "   ", service: "s", account: "a"))
        XCTAssertNil(store.text(service: "s", account: "a"))
        XCTAssertFalse(UnsupportedSecretStore().save(text: "x", service: "s", account: "a"))
    }
}

final class ProcessSpawnerConformanceTests: XCTestCase {
    private func run(_ spawner: ProcessSpawner, _ spec: ProcessSpec, stdin: String? = nil) throws -> (code: Int32, out: String, err: String) {
        let process = try spawner.spawn(spec)
        if let stdin, let input = process.input {
            try input.write(contentsOf: Data(stdin.utf8))
            try input.close()
        }
        let err = process.error
        let errData = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData.data = err?.readDataToEndOfFile() ?? Data(); group.leave() }
        let out = process.output?.readDataToEndOfFile() ?? Data()
        group.wait()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: errData.data, as: UTF8.self))
    }

    private final class Box: @unchecked Sendable { var data = Data() }

    private var spawners: [ProcessSpawner] { [POSIXProcessSpawner()] }

    func testExitCodes() throws {
        for spawner in spawners {
            XCTAssertEqual(try run(spawner, .shell("exit 0")).code, 0)
            XCTAssertEqual(try run(spawner, .shell("exit 7")).code, 7)
        }
    }

    func testShellMapsToBinShDashC() throws {
        let process = try POSIXProcessSpawner().shell(command: "echo $0 $#", environment: nil)
        let out = String(decoding: process.output?.readDataToEndOfFile() ?? Data(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "/bin/sh 0")
    }

    func testStdinReachesTheProcess() throws {
        var spec = ProcessSpec.shell("cat")
        spec.input = .pipe
        for spawner in spawners {
            XCTAssertEqual(try run(spawner, spec, stdin: "hello\nworld").out, "hello\nworld")
        }
    }

    func testStdinIsEmptyUnlessAPipeWasAsked() throws {
        XCTAssertEqual(try run(POSIXProcessSpawner(), .shell("cat; echo done")).out, "done\n")
    }

    func testStdoutAndStderrAreSeparate() throws {
        for spawner in spawners {
            let result = try run(spawner, .shell("echo out; echo err 1>&2; exit 3"))
            XCTAssertEqual(result.out, "out\n")
            XCTAssertEqual(result.err, "err\n")
            XCTAssertEqual(result.code, 3)
        }
    }

    func testStderrCanMergeIntoStdout() throws {
        var spec = ProcessSpec.shell("echo out; echo err 1>&2")
        spec.error = .mergedIntoOutput
        let result = try run(POSIXProcessSpawner(), spec)
        XCTAssertEqual(result.out, "out\nerr\n")
        XCTAssertEqual(result.err, "")
    }

    func testEnvironmentIsExactlyWhatWasPassed() throws {
        for spawner in spawners {
            let result = try run(spawner, .shell("echo $IRONPET_CONFORMANCE; echo ${HOME-unset}", environment: ["IRONPET_CONFORMANCE": "yes", "PATH": "/usr/bin:/bin"]))
            XCTAssertEqual(result.out, "yes\nunset\n")
        }
    }

    func testEnvironmentIsInheritedWhenNil() throws {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        XCTAssertEqual(try run(POSIXProcessSpawner(), .shell("echo $HOME")).out, home + "\n")
    }

    func testWorkingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-spawn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var spec = ProcessSpec.shell("pwd -P")
        spec.directory = dir.path
        for spawner in spawners {
            XCTAssertEqual(try run(spawner, spec).out.trimmingCharacters(in: .whitespacesAndNewlines), String(cString: realpath(dir.path, nil)))
        }
    }

    func testMissingExecutableThrows() {
        for spawner in spawners {
            XCTAssertThrowsError(try spawner.spawn(ProcessSpec(executable: "/nonexistent/ironpet-agent"))) { error in
                XCTAssertTrue(error.localizedDescription.contains("/nonexistent/ironpet-agent"), "\(error)")
            }
        }
    }

    func testSignalEndsAreReported() throws {
        let process = try POSIXProcessSpawner().spawn(.shell("sleep 30"))
        XCTAssertTrue(process.isRunning)
        process.terminate()
        process.waitUntilExit()
        XCTAssertEqual(process.exit, .signal(SIGTERM))
        XCTAssertFalse(process.isRunning)
    }

    func testOwnProcessGroupLetsASignalReachChildren() throws {
        var spec = ProcessSpec.shell("sleep 30 & wait")
        let process = try POSIXProcessSpawner().spawn(spec)
        usleep(200_000)
        process.signalGroup(SIGKILL)
        process.waitUntilExit()
        XCTAssertEqual(process.exit, .signal(SIGKILL))
        var gone = false
        for _ in 0..<50 where !gone {
            gone = killpg(process.pid, 0) != 0
            if !gone { usleep(100_000) }
        }
        XCTAssertTrue(gone, "the child of the shell died with the group")
    }

    func testWhenExitedCallsBackAfterAndBeforeTheExit() throws {
        let process = try POSIXProcessSpawner().spawn(.shell("exit 4"))
        let first = expectation(description: "first")
        process.whenExited { XCTAssertEqual($0, .code(4)); first.fulfill() }
        wait(for: [first], timeout: 5)
        let late = expectation(description: "late")
        process.whenExited { XCTAssertEqual($0, .code(4)); late.fulfill() }
        wait(for: [late], timeout: 1)
    }
}

final class ClockAndAppInfoConformanceTests: XCTestCase {
    func testSystemClockReadsNowAndTheCurrentZone() throws {
        let clock = SystemClock()
        XCTAssertLessThan(abs(try clock.now.timeIntervalSinceNow), 1)
        XCTAssertEqual(try clock.timeZone, TimeZone.current)
    }

    func testMacAppInfoFindsTheOwnerThroughTheProcessTree() throws {
        // pid 300 runs in /bin/zsh, started by 200, which lives inside Band.app.
        let parents: [Int32: Int32] = [300: 200, 200: 100]
        let paths: [Int32: String] = [300: "/bin/zsh", 200: "/Applications/Band.app/Contents/MacOS/Band"]
        XCTAssertEqual(MacAppInfo.owningBundleID(pid: 300, parent: { parents[$0] }, executablePath: { paths[$0] }, bundleID: { _ in "com.band" }), "com.band")
        XCTAssertNil(MacAppInfo.owningBundleID(pid: 999_999, parent: { _ in nil }, executablePath: { _ in nil }))
    }

    func testMacAppInfoAnswersForTheRealProcessAndAnUnknownApp() throws {
        let info = MacAppInfo()
        XCTAssertNoThrow(try info.owningBundleID(pid: getpid()))
        XCTAssertNil(try info.displayName(bundleID: "no.such.bundle.ironpet"))
    }
}
