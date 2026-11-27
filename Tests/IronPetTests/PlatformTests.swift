import XCTest
@testable import IronPet
@testable import IronPetCore

/// Records every service and account that is read or written, so a test can pin the strings stored items are found by.
final class RecordingSecretStore: SecretStore, @unchecked Sendable {
    struct Call: Equatable { let op: String; let service: String; let account: String }
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var log: [Call] = []

    var calls: [Call] { lock.withLock { log } }

    func get(service: String, account: String) throws -> Data? {
        lock.withLock { log.append(Call(op: "get", service: service, account: account)); return values["\(service)/\(account)"] }
    }
    func set(_ value: Data, service: String, account: String) throws {
        lock.withLock { log.append(Call(op: "set", service: service, account: account)); values["\(service)/\(account)"] = value }
    }
    func delete(service: String, account: String) throws {
        lock.withLock { log.append(Call(op: "delete", service: service, account: account)); values["\(service)/\(account)"] = nil }
    }
}

struct FakeAppInfo: AppInfo {
    var owners: [Int32: String]
    func owningBundleID(pid: Int32) throws -> String? { owners[pid] }
    func displayName(bundleID: String) throws -> String? { bundleID }
}

struct FixedClock: WallClock {
    var date: Date
    var zone: TimeZone
    var now: Date { date }
    var timeZone: TimeZone { zone }
}

@MainActor
final class PlatformTests: XCTestCase {
    /// The Mac platform over the real recorder and speaker, and a capture service on an in-memory database.
    static func macPlatform() -> Platform {
        let capture = CaptureService(store: CaptureStore(database: APITestSupport.memoryDatabase()), config: { Config().screenCapture })
        return Platform.mac(meetings: MeetingController(), speech: SpeechPlayer(), capture: capture)
    }

    func testMacPlatformReportsEveryCapabilityAsSupported() {
        let capabilities = Self.macPlatform().capabilities
        XCTAssertEqual(capabilities.map(\.name), ["SecretStore", "ProcessSpawner", "LogSink", "AppInfo", "WallClock", "MeetingRecorder",
                                                  "CaptureControl", "SpeechOutput", "PetAssets", "FileIntake", "PresenceSource", "URLOpener",
                                                  "AudioTranscoder"])
        XCTAssertTrue(capabilities.allSatisfy(\.supported))
    }

    func testUnsupportedPlatformReportsEveryCapabilityAsUnsupported() {
        XCTAssertTrue(Platform.unsupported.capabilities.allSatisfy { !$0.supported })
    }

    func testCapabilitiesReportOnlyTheUnsupportedAdapter() {
        var platform = Self.macPlatform()
        platform.secrets = UnsupportedSecretStore()
        XCTAssertEqual(platform.capabilities.filter { !$0.supported }.map(\.name), ["SecretStore"])
    }

    func testAFakePlatformCanBeBuiltFromFakes() throws {
        let platform = Platform(secrets: InMemorySecretStore(), processes: POSIXProcessSpawner(), log: StderrLogSink(),
                                appInfo: FakeAppInfo(owners: [1: "x"]), clock: FixedClock(date: Date(timeIntervalSince1970: 5), zone: TimeZone(identifier: "UTC")!),
                                meetings: FakeMeetingRecorder(), capture: FakeCaptureControl(), speech: FakeSpeechOutput(), pets: FakePetAssets(),
                                files: FakeFileIntake(), presence: FakePresenceSource(), opener: FakeURLOpener(), audio: FakeAudioTranscoder())
        XCTAssertEqual(try platform.clock.now, Date(timeIntervalSince1970: 5))
        XCTAssertTrue(platform.capabilities.allSatisfy(\.supported))
    }

    func testEveryUnsupportedAdapterNamesItsCapability() async throws {
        let platform = PlatformName.current
        func expect(_ capability: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
            XCTAssertThrowsError(try body(), file: file, line: line) {
                XCTAssertEqual($0 as? CapabilityError, .unsupported(capability: capability, platform: platform), file: file, line: line)
            }
        }
        let secrets = UnsupportedSecretStore()
        expect("SecretStore") { _ = try secrets.get(service: "s", account: "a") }
        expect("SecretStore") { try secrets.set(Data(), service: "s", account: "a") }
        expect("SecretStore") { try secrets.delete(service: "s", account: "a") }
        let processes = UnsupportedProcessSpawner()
        expect("ProcessSpawner") { _ = try processes.spawn(ProcessSpec(executable: "/bin/sh")) }
        expect("ProcessSpawner") { _ = try processes.shell(command: "true", environment: nil) }
        let appInfo = UnsupportedAppInfo()
        expect("AppInfo") { _ = try appInfo.owningBundleID(pid: 1) }
        expect("AppInfo") { _ = try appInfo.displayName(bundleID: "x") }
        let clock = UnsupportedClock()
        expect("WallClock") { _ = try clock.now }
        expect("WallClock") { _ = try clock.timeZone }
        XCTAssertFalse(UnsupportedLogSink().isSupported)
        let presence = UnsupportedPresenceSource()
        expect("PresenceSource") { _ = try presence.idleSeconds() }
        XCTAssertEqual(presence.idleOrZero(), 0, "an unsupported source reports a user who is at the keyboard")
        XCTAssertFalse(presence.isScreenLocked())
        XCTAssertFalse(presence.wokeSince(.distantPast))
        XCTAssertTrue(presence.micCalls().isEmpty)
        let opener = UnsupportedURLOpener()
        expect("URLOpener") { try opener.open(URL(string: "https://example.com")!) }
        let audio = UnsupportedAudioTranscoder()
        expect("AudioTranscoder") { _ = try audio.wav(from: URL(fileURLWithPath: "/x.wav"), maxSeconds: 1) }
        let mic = UnsupportedConversationMic()
        expect("ConversationListening") { try mic.start() }
        do {
            _ = try await UnsupportedDiarizer().diarize(wav: URL(fileURLWithPath: "/x.wav"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CapabilityError, .unsupported(capability: "SpeakerDiarizing", platform: platform))
        }
        XCTAssertEqual(CapabilityError.unsupported(capability: "SecretStore", platform: "Linux").localizedDescription, "SecretStore is not available on Linux")
    }

    // MARK: Items stored before the adapters existed must still be found

    func testVoiceKeyUsesTheSameServiceAndAccountAsBefore() {
        let store = RecordingSecretStore()
        let key = VoiceKey(store: store)
        XCTAssertTrue(key.save("  abc "))
        XCTAssertEqual(key.load(), "abc")
        key.delete()
        XCTAssertEqual(Set(store.calls.map { "\($0.service)/\($0.account)" }), ["ironpet.voice/api-key"])
        XCTAssertEqual(store.calls.map(\.op), ["delete", "set", "get", "delete"])
    }

    func testTelegramTokenUsesTheSameServiceAndAccountAsBefore() {
        let store = RecordingSecretStore()
        let token = TelegramToken(secrets: store)
        XCTAssertTrue(token.save("123:abc"))
        XCTAssertEqual(token.load(), "123:abc")
        XCTAssertTrue(token.save(""))
        XCTAssertNil(token.load())
        XCTAssertEqual(Set(store.calls.map { "\($0.service)/\($0.account)" }), ["ironpet.telegram/bot-token"])
    }

    func testVoiceStoreKeyIsCreatedOnceUnderTheSameServiceAndAccount() throws {
        let store = RecordingSecretStore()
        let first = try XCTUnwrap(VoiceStoreKey(store: store).load())
        let second = try XCTUnwrap(VoiceStoreKey(store: store).load())
        XCTAssertEqual(first.withUnsafeBytes { Data($0) }, second.withUnsafeBytes { Data($0) })
        XCTAssertEqual(Set(store.calls.map { "\($0.service)/\($0.account)" }), ["ironpet.voiceprints/store-key"])
        XCTAssertEqual(store.calls.map(\.op), ["get", "set", "get"])
    }

    func testVoiceStoreKeyIsNilWhenTheStoreCannotKeepIt() {
        XCTAssertNil(VoiceStoreKey(store: UnsupportedSecretStore()).load())
        XCTAssertNil(VoiceKey(store: UnsupportedSecretStore()).load())
    }

    @MainActor
    func testSessionStoreAsksAppInfoWhichAppOwnsTheAgent() {
        let store = SessionStore()
        store.appInfo = FakeAppInfo(owners: [4242: "com.example.terminal"])
        var origin = SessionOrigin()
        origin.pid = 4242
        store.apply(HookEvent(source: .claude, name: "UserPromptSubmit", payload: ["session_id": "s1", "prompt": "hi"], origin: origin))
        XCTAssertEqual(store.sessions["claude:s1"]?.origin.ownerBundleID, "com.example.terminal")
        origin.pid = 1
        store.apply(HookEvent(source: .claude, name: "UserPromptSubmit", payload: ["session_id": "s2", "prompt": "hi"], origin: origin))
        XCTAssertNil(store.sessions["claude:s2"]?.origin.ownerBundleID)
    }

    @MainActor
    func testSessionStoreWithoutAppInfoLeavesTheOwnerEmpty() {
        let store = SessionStore()
        var origin = SessionOrigin()
        origin.pid = getpid()
        store.apply(HookEvent(source: .claude, name: "UserPromptSubmit", payload: ["session_id": "s1", "prompt": "hi"], origin: origin))
        XCTAssertNil(store.sessions["claude:s1"]?.origin.ownerBundleID)
    }
}

/// Until the import allow-list test of PR 8 exists, these scans keep the files that moved off a platform API from reaching for it again.
final class AdapterBoundaryTests: XCTestCase {
    private static let roots: [URL] = {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return ["Sources/IronPet", "Sources/IronPetCore"].map { repo.appendingPathComponent($0) }
    }()

    private static func files() -> [(path: String, code: String)] {
        roots.flatMap { root -> [(path: String, code: String)] in
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
            return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
                return (String(url.path.dropFirst(root.path.count + 1)), code)
            }
        }
    }

    /// Files that may name a platform API: the Mac adapters, and the TLS identity and listener code that stays Mac code.
    private func offenders(_ pattern: String, allowed: (String) -> Bool) -> [String] {
        Self.files().filter { !allowed($0.path) && $0.code.range(of: pattern, options: .regularExpression) != nil }.map(\.path).sorted()
    }

    private func isMacAdapter(_ path: String) -> Bool { path.hasPrefix("Platform/Mac/") }

    func testSecItemCallsStayInTheKeychainAdapter() {
        // RemoteTLSKeychain builds the TLS identity (SecItemImport, SecItemAdd for the certificate). That is Mac code, not secret storage.
        XCTAssertEqual(offenders(#"\bSecItem\w*\("#) { isMacAdapter($0) || $0 == "Remote/RemoteTLSKeychain.swift" }, [])
    }

    func testSecretConsumersDoNotImportSecurityOrDarwin() {
        let moved = ["Voice/VoiceKey.swift", "Telegram/TelegramAPI.swift", "Meeting/VoiceStore.swift", "Sessions/SessionStore.swift"]
        for file in Self.files() where moved.contains(file.path) {
            XCTAssertNil(file.code.range(of: #"^import (Security|Darwin)\b"#, options: [.regularExpression]), "\(file.path) imports a platform module")
        }
    }

    func testProcessInfoLookupsStayInTheMacAdapter() {
        // RemoteNetwork lists the Mac's network interfaces with sysctl-family calls and stays Mac code.
        XCTAssertEqual(offenders(#"\b(proc_pidpath|sysctl)\("#) { isMacAdapter($0) || $0 == "Remote/RemoteNetwork.swift" }, [])
    }

    func testPosixSpawnStaysInTheSpawner() {
        XCTAssertEqual(offenders(#"\bposix_spawn\w*"#) { $0 == "Platform/POSIXProcessSpawner.swift" }, [])
    }

    func testSpawnSitesUseTheSpawnerNotProcess() {
        let sites = ["Chat/ACP/ACPAgent.swift", "Chat/ACP/ACPBackend.swift", "Chat/ACP/ACPClient.swift", "Chat/ACP/ACPRuntime.swift",
                     "Chat/ACP/TerminalLauncher.swift", "Automations/PollEngine.swift", "Automations/StreamProcess.swift"]
        for file in Self.files() where sites.contains(file.path) {
            XCTAssertNil(file.code.range(of: #"\bProcess\(\)"#, options: .regularExpression), "\(file.path) starts a Process itself")
        }
    }

    func testCorePlatformFilesImportNoMacModule() {
        for file in Self.files() where file.path.hasPrefix("Platform/") && !isMacAdapter(file.path) {
            XCTAssertNil(file.code.range(of: #"^import (AppKit|SwiftUI|Combine|Security|os)\b"#, options: .regularExpression),
                         "\(file.path) imports a Mac-only module")
        }
    }

    func testNoAdapterIsLookedUpGlobally() {
        XCTAssertEqual(offenders(#"\b(Platform|KeychainSecretStore|POSIXProcessSpawner|MacAppInfo|OSLogLog)\.shared\b"#) { _ in false }, [])
        XCTAssertEqual(offenders(#"static (let|var) (shared|current|default)\w*\s*(:\s*(any )?(SecretStore|ProcessSpawner|AppInfo|LogSink|WallClock|Platform))"#) { _ in false }, [])
    }
}

final class LogSinkTests: XCTestCase {
    final class Capture: LogSink, @unchecked Sendable {
        var lines: [String] = []
        func note(category: String, _ message: String) { lines.append("\(category): \(message)") }
    }

    func testALogWithASinkWritesThroughIt() {
        let capture = Capture()
        let log = Log(subsystem: "com.ironpet", category: "chat", sink: capture)
        log.notice("one")
        log.info("two")
        XCTAssertEqual(capture.lines, ["chat: one", "chat: two"])
    }
}
