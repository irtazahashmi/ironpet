import XCTest
@testable import IronPetKit

final class VoiceTurnDetectorTests: XCTestCase {
    private func run(_ detector: inout VoiceTurnDetector, level: Float, seconds: Double) -> VoiceTurnDetector.Action? {
        var result: VoiceTurnDetector.Action?
        for _ in 0..<Int((seconds * 10).rounded()) { result = result ?? detector.feed(level: level, duration: 0.1) }
        return result
    }

    func testTheDefaultsMatchTheMac() {
        XCTAssertEqual(VoiceTurnDetector.defaultEndPause, 2.5)
        XCTAssertEqual(VoiceTurnDetector.defaultSilence, 20)
    }

    func testAMessageEndsAfterTheEndPauseFollowingSpeech() {
        var detector = VoiceTurnDetector()
        XCTAssertNil(run(&detector, level: 0.7, seconds: 1))
        XCTAssertNil(run(&detector, level: 0, seconds: 2.3))
        XCTAssertEqual(run(&detector, level: 0, seconds: 0.4), .endMessage)
    }

    func testAShortPauseInsideASentenceDoesNotEndIt() {
        var detector = VoiceTurnDetector()
        XCTAssertNil(run(&detector, level: 0.7, seconds: 1))
        XCTAssertNil(run(&detector, level: 0, seconds: 1))
        XCTAssertNil(run(&detector, level: 0.7, seconds: 1))
        XCTAssertNil(run(&detector, level: 0, seconds: 2.3))
        XCTAssertEqual(run(&detector, level: 0, seconds: 0.4), .endMessage)
    }

    func testSilenceBeforeAnySpeechGivesUp() {
        var detector = VoiceTurnDetector()
        XCTAssertNil(run(&detector, level: 0, seconds: 19.5))
        XCTAssertEqual(run(&detector, level: 0, seconds: 1), .giveUp)
    }

    func testAClickDoesNotStartAMessage() {
        var detector = VoiceTurnDetector()
        _ = run(&detector, level: 0.7, seconds: 0.2)
        XCTAssertFalse(detector.hasSpeech)
        XCTAssertEqual(run(&detector, level: 0, seconds: 20), .giveUp)
    }

    func testItReportsAnActionOnlyOnce() {
        var detector = VoiceTurnDetector(endPause: 1, silence: 5)
        XCTAssertEqual(run(&detector, level: 0, seconds: 6), .giveUp)
        XCTAssertNil(run(&detector, level: 0, seconds: 6))
    }

    func testSteadyNoiseBelowTheThresholdCountsAsSilence() {
        var detector = VoiceTurnDetector()
        XCTAssertEqual(run(&detector, level: 0.1, seconds: 21), .giveUp)
    }
}
