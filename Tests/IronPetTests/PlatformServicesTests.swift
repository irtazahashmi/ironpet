import XCTest
@testable import IronPet

// MARK: Test doubles for the Mac-only services

@MainActor
final class FakeMeetingRecorder: MeetingRecorder {
    var calls: [String] = []
    var named: [(id: Int, name: String)] = []
    var dismissedSpeakers: [(id: Int, mixed: Bool)] = []
    let changes = ChangeSignal()
    weak var events: APIEventBus?
    var phase: MeetingPhase = .idle
    var isRecording = false
    var apps: [AudioApp] = []
    var choice: AudioChoice = .allSystemAudio
    var notice: String?
    var appName = ""
    var startedAt: Date?
    var folder: URL?
    let myLevels = LevelBuffer()
    let theirLevels = LevelBuffer()
    var counts: (done: Int, waiting: Int, failed: Int) = (0, 0, 0)
    var recentLines: [MeetingLine] = []
    var summary: MeetingSummaryState = .none
    var canRegenerateSummary = false
    var regeneratingSummary = false
    var speakerTable = MeetingSpeakerTable()
    var speakersToName: [MeetingSpeaker] = []
    var hasSpeakersToName: Bool { !speakersToName.isEmpty }
    var storedNames: [String] = []
    let voiceStore: VoiceStore = .unwired
    var onLabelSpeakers: (() -> Void)?

    func knownNames(stored: [String]) -> [String] { stored }
    func sampleLine(for id: Int) -> String? { nil }
    func nameSpeaker(_ id: Int, as name: String) { named.append((id, name)) }
    func dismissSpeaker(_ id: Int, mixed: Bool) { dismissedSpeakers.append((id, mixed)) }
    func start() throws { calls.append("start") }
    func stop() throws { calls.append("stop") }
    func dismiss() { calls.append("dismiss") }
    func confirmDiscard() { calls.append("confirmDiscard") }
    func retryFailed() { calls.append("retryFailed") }
    func openTranscript() { calls.append("openTranscript") }
    func openSummary() { calls.append("openSummary") }
    func openInChat() { calls.append("openInChat") }
    func regenerateSummary() { calls.append("regenerateSummary") }
}

final class FakeCaptureControl: CaptureControl, @unchecked Sendable { // Touched from one test at a time.
    var calls: [String] = []
    @MainActor let model = CaptureStatusModel()

    func refreshModel() { calls.append("refreshModel") }
    func pause(for seconds: TimeInterval) throws { calls.append("pause \(seconds)") }
    func pauseUntilTomorrow() throws { calls.append("pauseUntilTomorrow") }
    func resume() throws { calls.append("resume") }
    func clearCaptures() throws { calls.append("clear") }
    func recentCaptures(limit: Int) -> [StoredCapture] { calls.append("recent \(limit)"); return [] }
    func searchCaptures(_ query: String, app: String?, since: Date?, until: Date?, limit: Int) -> [CaptureHit] {
        calls.append("search \(query) \(app ?? "-") \(limit)")
        return []
    }
    func captureText(_ id: Int64) -> String? { calls.append("text \(id)"); return "text of \(id)" }
    func seenApps() -> [(bundleId: String, name: String, captures: Int)] { [("com.example", "Example", 3)] }
    func callTool(_ name: String, _ args: [String: Any]) -> Result<Any, ScreenMCP.Failure> { calls.append("tool \(name)"); return .success("ok") }
}

@MainActor
final class FakeSpeechOutput: SpeechOutput {
    var spoken: [(text: String, id: UUID)] = []
    var stops = 0
    var previews: [String] = []
    let changes = ChangeSignal()
    var speakingID: UUID?
    var isSpeaking: Bool { speakingID != nil }
    var isEnabled: () -> Bool = { false }
    var onFailure: ((String) -> Void)?
    var voiceKey = VoiceKey.unsupported

    func speak(_ markdown: String, id: UUID) throws { spoken.append((markdown, id)); speakingID = id }
    func stop() { stops += 1; speakingID = nil }
    func preview(_ text: String, using synthesizer: Synthesizer) async throws { previews.append(text) }
}

struct FakeFileIntake: FileIntake {
    final class Log: @unchecked Sendable { // Appended to from one test at a time.
        var saved: [(name: String, data: Data)] = []
        var copied: [URL] = []
        var prunes = 0
    }

    var log = Log()
    var directory = URL(fileURLWithPath: "/tmp/fake-attachments")

    func copy(_ file: URL) throws -> URL { log.copied.append(file); return directory.appendingPathComponent(file.lastPathComponent) }
    func save(_ data: Data, named fileName: String) throws -> URL {
        log.saved.append((fileName, data))
        return directory.appendingPathComponent(fileName)
    }
    func prune() { log.prunes += 1 }
}

struct FakePetAssets: PetAssets {
    final class Log: @unchecked Sendable { // Appended to from one test at a time.
        var entriesCurrent: [String?] = []
        var importedSheets: [URL] = []
        var importedBackgrounds: [(source: URL, replacing: String?)] = []
    }

    var log = Log()
    var libraryFolder = URL(fileURLWithPath: "/tmp/fake-pets")
    var bundledFolder: URL?
    var backgroundsFolder = URL(fileURLWithPath: "/tmp/fake-backgrounds")
    var builtInNames: [String] { ["ghost"] }
    var backgroundName = "custom-fake.png"

    func entries(current: String?) throws -> [PetEntry] { log.entriesCurrent.append(current); return [] }
    func selectedID(in entries: [PetEntry], sprite: String?) -> String? { nil }
    func select(_ entry: PetEntry, in config: inout Config) {}
    func importSheet(_ source: URL) throws -> PetEntry { log.importedSheets.append(source); throw PetLibrary.ImportError.notAnAtlas(source.lastPathComponent) }
    func standardizedID(_ path: String) -> String { path }
    func sheetFiles() -> (bundled: [URL], library: [URL]) { ([], []) }
    func folderSignature() -> [String] { [] }
    func importBackground(from source: URL, replacing: String?) throws -> String {
        log.importedBackgrounds.append((source, replacing))
        return backgroundName
    }
}

// MARK: The facades call the doubles

@MainActor
final class PlatformServicesFacadeTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-services-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testMeetingsCallsReachTheRecorderWithTheSameArguments() throws {
        let recorder = FakeMeetingRecorder()
        let api = APITestSupport.makeAPI(meeting: recorder)
        api.meetings.start()
        XCTAssertThrowsError(try api.meetings.stopRecording()) { XCTAssertEqual(($0 as? APIError)?.code, .conflict) }
        XCTAssertEqual(recorder.calls, ["start"], "stop is refused while nothing records")
        recorder.isRecording = true
        recorder.phase = .recording
        recorder.appName = "Zoom"
        try api.meetings.stopRecording()
        api.meetings.dismiss()
        api.meetings.retryFailed()
        api.meetings.confirmDiscard()
        api.meetings.regenerateSummary()
        XCTAssertEqual(recorder.calls, ["start", "stop", "dismiss", "retryFailed", "confirmDiscard", "regenerateSummary"])
        XCTAssertEqual(api.meetings.status.phase, "recording")
        XCTAssertEqual(api.meetings.status.appName, "Zoom")

        recorder.speakersToName = [MeetingSpeaker(id: 3, centroid: [], seconds: 5)]
        try api.meetings.nameSpeaker(NameSpeakerRequest(speaker: 3, name: "Ana"))
        XCTAssertEqual(recorder.named.map(\.id), [3])
        XCTAssertEqual(recorder.named.map(\.name), ["Ana"])
    }

    func testMeetingsFollowTheRecordersChanges() {
        let recorder = FakeMeetingRecorder()
        let api = MeetingsAPI(recorder: recorder, library: MeetingLibrary(root: root))
        var sent = 0
        let token = api.changes.observe { sent += 1 }
        recorder.changes.send()
        XCTAssertEqual(sent, 1)
        token.cancel()
    }

    func testScreenCallsReachTheControlWithTheSameArguments() async throws {
        let control = FakeCaptureControl()
        let api = ScreenAPI(control: control)
        try api.pause(for: 90)
        api.pauseUntilTomorrow()
        api.resume()
        api.clear()
        api.refreshStatus()
        XCTAssertThrowsError(try api.pause(for: 0)) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
        _ = await api.recent(limit: 7)
        _ = try await api.search(ScreenSearchRequest(query: " hello ", app: "com.example", limit: 5))
        let text = await api.captureText(42)
        XCTAssertEqual(text, "text of 42")
        XCTAssertEqual(api.seenApps().map(\.bundleId), ["com.example"])
        _ = api.callTool("screen_search", [:])
        XCTAssertEqual(control.calls, ["pause 90.0", "pauseUntilTomorrow", "resume", "clear", "refreshModel", "recent 7", "search hello com.example 5",
                                       "text 42", "tool screen_search"])
    }

    func testVoiceCallsReachTheSpeakerWithTheSameArguments() async throws {
        let speech = FakeSpeechOutput()
        let api = APITestSupport.makeAPI(speech: speech)
        let item = UUID()
        try api.voice.speak(SpeakRequest(text: "Hello there, this is a reply.", item: item))
        XCTAssertEqual(speech.spoken.map(\.text), ["Hello there, this is a reply."])
        XCTAssertEqual(speech.spoken.map(\.id), [item])
        XCTAssertEqual(api.voice.speakingItem, item)
        XCTAssertTrue(api.voice.status.speaking)
        api.voice.stop()
        XCTAssertEqual(speech.stops, 1)
        try await api.voice.preview("A short line")
        XCTAssertEqual(speech.previews, ["A short line"])
        let key = VoiceKey.unsupported
        api.voice.voiceKey = key
        XCTAssertTrue(api.settings.config.speech.canSpeak)
        XCTAssertTrue(speech.isEnabled() == api.settings.config.speech.enabled, "the speaker follows the settings")
        XCTAssertThrowsError(try api.voice.speak(SpeakRequest(text: "```\ncode\n```"))) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
        XCTAssertEqual(speech.spoken.count, 1, "text with nothing to read never reaches the speaker")
    }

    func testPetCallsReachThePetAssetsWithTheSameArguments() async throws {
        let assets = FakePetAssets()
        let api = APITestSupport.makeAPI(petAssets: assets)
        api.settings.update { $0.pet.sprite = "~/elsewhere.png" }
        let pets = await api.pet.pets()
        XCTAssertTrue(pets.isEmpty)
        XCTAssertEqual(assets.log.entriesCurrent.compactMap { $0 }, ["~/elsewhere.png"])

        let sheet = root.appendingPathComponent("fox.png")
        XCTAssertThrowsError(try api.pet.importPet(sheet)) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
        XCTAssertEqual(assets.log.importedSheets, [sheet])

        api.settings.update { $0.chat.customImage = "custom-old.png" }
        let picture = root.appendingPathComponent("sky.png")
        try api.pet.importBackground(picture)
        XCTAssertEqual(assets.log.importedBackgrounds.map(\.source), [picture])
        XCTAssertEqual(assets.log.importedBackgrounds.map(\.replacing), ["custom-old.png"])
        XCTAssertEqual(api.settings.config.chat.customImage, "custom-fake.png")
        XCTAssertEqual(api.settings.config.chat.background, ChatBackground.customID)
    }

    func testChatUploadsReachTheFileIntakeByNameOnly() async throws {
        let files = FakeFileIntake()
        let session = ChatSession(restore: false)
        session.workspace = root
        session.turnRunner = { _, _ in }
        let chat = ChatAPI(session: session, files: files)
        let phone = ChatOrigin(client: "ios", ref: "device-1")
        _ = try await chat.send(SendChatRequest(text: "see file", origin: phone, uploads: [ChatUpload(fileName: "../../evil.txt", data: Data("hi".utf8))]))
        XCTAssertEqual(files.log.saved.map(\.name), ["evil.txt"])
        XCTAssertEqual(files.log.saved.map(\.data), [Data("hi".utf8)])
    }
}

// MARK: Unsupported adapters and conformance

@MainActor
final class PlatformServicesConformanceTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-conformance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testEveryUnsupportedAdapterThrowsTheCapabilityError() async throws {
        let platform = PlatformName.current
        func expect(_ capability: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
            XCTAssertThrowsError(try body(), file: file, line: line) {
                XCTAssertEqual($0 as? CapabilityError, .unsupported(capability: capability, platform: platform), file: file, line: line)
            }
        }
        let meetings = UnsupportedMeetingRecorder()
        expect("MeetingRecorder") { try meetings.start() }
        expect("MeetingRecorder") { try meetings.stop() }
        XCTAssertEqual(meetings.phase, .idle)
        XCTAssertFalse(meetings.isRecording)

        let capture = UnsupportedCaptureControl()
        expect("CaptureControl") { try capture.pause(for: 60) }
        expect("CaptureControl") { try capture.pauseUntilTomorrow() }
        expect("CaptureControl") { try capture.resume() }
        expect("CaptureControl") { try capture.clearCaptures() }
        XCTAssertTrue(capture.recentCaptures(limit: 5).isEmpty)

        let speech = UnsupportedSpeechOutput()
        expect("SpeechOutput") { try speech.speak("hello", id: UUID()) }
        do {
            try await speech.preview("hello", using: Synthesizer.saved(voiceKey: .unsupported))
            XCTFail("preview should throw")
        } catch {
            XCTAssertEqual(error as? CapabilityError, .unsupported(capability: "SpeechOutput", platform: platform))
        }

        let pets = UnsupportedPetAssets()
        expect("PetAssets") { _ = try pets.entries(current: nil) }
        expect("PetAssets") { _ = try pets.importSheet(root) }
        expect("PetAssets") { _ = try pets.importBackground(from: root, replacing: nil) }

        let files = UnsupportedFileIntake()
        expect("FileIntake") { _ = try files.copy(root) }
        expect("FileIntake") { _ = try files.save(Data(), named: "a") }
    }

    func testThePlatformReportsTheNewCapabilitiesAsUnsupported() {
        let names = ["MeetingRecorder", "CaptureControl", "SpeechOutput", "PetAssets", "FileIntake"]
        let unsupported = Platform.unsupported.capabilities.filter { names.contains($0.name) }
        XCTAssertEqual(unsupported.map(\.name), names)
        XCTAssertTrue(unsupported.allSatisfy { !$0.supported })
    }

    func testFileIntakeSuiteRunsAgainstThePortableHalf() throws {
        let intake = FolderFileIntake(directory: root.appendingPathComponent("attachments"))
        let source = root.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: source)
        let copy = try intake.copy(source)
        XCTAssertEqual(copy.lastPathComponent, "note.txt")
        XCTAssertEqual(try Data(contentsOf: copy), Data("hello".utf8))
        XCTAssertThrowsError(try intake.copy(root), "a folder is not a file")
        XCTAssertThrowsError(try intake.copy(root.appendingPathComponent("missing.txt")))
        let saved = try intake.save(Data("x".utf8), named: "../../evil.txt")
        XCTAssertTrue(saved.lastPathComponent.hasSuffix("-evil.txt"))
        XCTAssertEqual(saved.deletingLastPathComponent().standardizedFileURL.path, intake.directory.standardizedFileURL.path)
        XCTAssertTrue(try intake.save(Data(), named: "").lastPathComponent.hasSuffix("-file"))
    }

    func testMacFileIntakeKeepsItsFolderAndConformsHeadless() {
        let intake: FileIntake = MacFileIntake()
        XCTAssertTrue(intake.isSupported)
        XCTAssertEqual(intake.directory, ScreenCapture.directory.appendingPathComponent("attachments"))
    }

    func testMacPetAssetsRejectWhatIsNotASheetOrAnImage() throws {
        let assets = MacPetAssets(library: root.appendingPathComponent("pets"), bundled: nil, backgrounds: root.appendingPathComponent("backgrounds"))
        XCTAssertTrue(assets.isSupported)
        XCTAssertEqual(assets.builtInNames, PetLibrary.builtInNames)
        XCTAssertTrue(try assets.entries(current: nil).isEmpty)
        let text = root.appendingPathComponent("note.png")
        try Data("not a picture".utf8).write(to: text)
        XCTAssertThrowsError(try assets.importSheet(text))
        XCTAssertThrowsError(try assets.importBackground(from: text, replacing: nil))
        XCTAssertEqual(assets.folderSignature(), [])
    }

    func testMacCaptureControlPausesAndResumesTheModel() async throws {
        let control = CaptureService(store: CaptureStore(database: APITestSupport.memoryDatabase()), config: { Config().screenCapture })
        XCTAssertTrue(control.isSupported)
        try control.pause(for: 60)
        try await waitForModel(control) { $0.paused }
        try control.resume()
        try await waitForModel(control) { !$0.paused }
        XCTAssertTrue(control.recentCaptures(limit: 5).isEmpty)
    }

    private func waitForModel(_ control: CaptureService, _ condition: @MainActor (CaptureStatusModel) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(control.model), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(control.model))
    }
}

// MARK: The facades name no Mac-only service

final class FacadeBoundaryTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/IronPet")

    private func code(_ path: String) throws -> String {
        let text = try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    private let concrete = #"\b(MeetingController|CaptureService|SpeechPlayer|PetLibrary|ClipPlayer|MacFileIntake|MacPetAssets)\b"#
    private let frameworks = #"\b(import (AVFoundation|AVFAudio|ScreenCaptureKit)|AV[A-Z]\w+|SC(Stream|Shareable|ContentFilter)\w*)\b"#

    func testNoFacadeNamesAMacOnlyServiceOrFramework() throws {
        for path in ["API/MeetingsAPI.swift", "API/VoiceAPI.swift", "API/ScreenAPI.swift", "API/PetAPI.swift"] {
            let source = try code(path)
            XCTAssertNil(source.range(of: concrete, options: .regularExpression), "\(path) names a Mac-only service")
            XCTAssertNil(source.range(of: frameworks, options: .regularExpression), "\(path) names an AVFoundation or ScreenCaptureKit type")
        }
    }

    func testChatAPIIntakeGoesThroughFileIntake() throws {
        // ChatAPI takes the Mac's intake as a default argument only. Nothing else in the file names it.
        let source = try code("API/ChatAPI.swift")
        XCTAssertNil(source.range(of: #"\b(PetLibrary|CaptureService|SpeechPlayer|MeetingController)\b"#, options: .regularExpression))
        XCTAssertEqual(source.components(separatedBy: "MacFileIntake").count - 1, 1)
        XCTAssertNil(source.range(of: #"FileManager\.default\.createDirectory"#, options: .regularExpression), "uploads are written through FileIntake")
    }

    func testStoresHoldProtocolsNotMacClasses() throws {
        let source = try code("API/IronPetAPI.swift")
        guard let start = source.range(of: "struct Stores {"), let end = source.range(of: "let events: APIEventBus") else { return XCTFail("Stores not found") }
        let stores = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertNil(stores.range(of: #"\b(MeetingController|CaptureService|SpeechPlayer|PetLibrary|ClipPlayer)\b"#, options: .regularExpression))
        for field in ["meeting: MeetingRecorder", "speech: SpeechOutput", "petAssets: PetAssets", "files: FileIntake"] {
            XCTAssertTrue(stores.contains(field), "Stores lacks \(field)")
        }
        XCTAssertNil(source.range(of: #"attach\(capture \w+: CaptureService\)"#, options: .regularExpression))
    }

    func testNewPlatformProtocolFilesImportNoMacModule() throws {
        for path in ["Platform/MeetingRecorder.swift", "Platform/CaptureControl.swift", "Platform/SpeechOutput.swift", "Platform/PetAssets.swift", "Platform/FileIntake.swift"] {
            let source = try code(path)
            XCTAssertNil(source.range(of: #"(?m)^import (AppKit|SwiftUI|Combine|AVFoundation|ScreenCaptureKit)\b"#, options: .regularExpression), "\(path) imports a Mac-only module")
        }
    }
}

@MainActor
final class FakePresenceSource: PresenceSource {
    var idle: TimeInterval = 0
    var locked = false
    var lastWake: Date?
    var calls: Set<String> = []
    var micStops = 0
    /// Read instead of `idle` when set, so a test's own clock can drive it.
    private let idleProvider: (() -> TimeInterval)?

    nonisolated init(idleProvider: (() -> TimeInterval)? = nil) { self.idleProvider = idleProvider }

    func idleSeconds() throws -> TimeInterval { idleProvider?() ?? idle }
    func isScreenLocked() -> Bool { locked }
    func wokeSince(_ date: Date) -> Bool { lastWake.map { $0 > date } ?? false }
    func micCalls() -> Set<String> { calls }
    func stopMicWatch() { micStops += 1 }
}

final class FakeURLOpener: URLOpener, @unchecked Sendable { // Appended to from one test at a time.
    var opened: [URL] = []
    func open(_ url: URL) throws { opened.append(url) }
}

struct FakeAudioTranscoder: AudioTranscoder {
    var result: Data?
    func wav(from file: URL, maxSeconds: Double) throws -> Data? { result }
}
