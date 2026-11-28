import AppIntents
import XCTest
@testable import IronPetRemote

/// The Action button and lock screen entry to voice mode. What only a real phone can show (the button, the locked screen, the
/// microphone in the background) is checked by hand.
@MainActor
final class StartVoiceModeIntentTests: XCTestCase {
    override func setUp() async throws { VoiceLaunch.shared.handler = nil }
    override func tearDown() async throws {
        VoiceLaunch.shared.handler = nil
        VoiceLaunch.timeout = .seconds(10)
    }

    // S1
    func testARequestStartsVoiceModeThroughTheRegisteredHandler() async {
        var starts = 0
        VoiceLaunch.shared.handler = { starts += 1; return true }
        let started = await VoiceLaunch.shared.start()
        XCTAssertTrue(started)
        XCTAssertEqual(starts, 1)
    }

    // S1
    func testARequestBeforeTheTabsExistWaitsForTheHandler() async {
        var starts = 0
        let request = Task { await VoiceLaunch.shared.start() }
        try? await Task.sleep(for: .milliseconds(50))
        VoiceLaunch.shared.handler = { starts += 1; return true }
        let started = await request.value
        XCTAssertTrue(started)
        XCTAssertEqual(starts, 1)
    }

    func testARequestFailsWhenTheTabsNeverCome() async {
        VoiceLaunch.timeout = .milliseconds(50)
        let started = await VoiceLaunch.shared.start()
        XCTAssertFalse(started)
    }

    // S1
    @available(iOS 18.0, *)
    func testTheIntentStartsVoiceModeAndIsOfferedToShortcuts() async throws {
        var starts = 0
        VoiceLaunch.shared.handler = { starts += 1; return true }
        _ = try await StartVoiceModeIntent().perform()
        XCTAssertEqual(starts, 1)
        XCTAssertFalse(StartVoiceModeIntent.openAppWhenRun, "the intent must not unlock the phone")
        XCTAssertTrue(StartVoiceModeIntent() is any AudioRecordingIntent, "the system lets it record from the background")
        XCTAssertEqual(IronPetShortcuts.appShortcuts.count, 1)
    }

    @available(iOS 18.0, *)
    func testTheIntentThrowsWhenListeningCannotStart() async {
        VoiceLaunch.shared.handler = { false }
        do {
            _ = try await StartVoiceModeIntent().perform()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is VoiceIntentError)
        }
    }

    /// App Store Connect rejects an upload whose intent titles, descriptions or phrases name an Apple product (ITMS-90626).
    /// This reads the metadata Xcode extracts into the app, which is what App Store Connect checks.
    func testTheIntentMetadataNamesNoAppleProduct() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "extract", withExtension: "actionsdata", subdirectory: "Metadata.appintents"))
        let metadata = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(metadata.contains("Starts listening"), "the metadata should hold the voice mode intent")
        for name in ["Mac", "iPhone", "iPad", "Siri", "Apple Watch"] {
            XCTAssertNil(metadata.range(of: "\\b\(name)\\b", options: [.regularExpression, .caseInsensitive]),
                         "the intent metadata names \(name), which App Store Connect rejects")
        }
    }

    // S3
    func testTheAppKeepsRecordingAndPlayingWithTheScreenLocked() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        XCTAssertEqual(modes, ["audio"])
    }
}
