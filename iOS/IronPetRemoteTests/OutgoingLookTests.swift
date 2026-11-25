import XCTest
@testable import IronPetRemote

/// How an unconfirmed message looks: dimmed, with a clock or a retry button, and what VoiceOver reads.
final class OutgoingLookTests: XCTestCase {
    private func look(_ state: OutgoingMessage.State, voice: Bool = false, text: String = "hello", queued: Bool = false) -> OutgoingLook {
        var message = OutgoingMessage(id: UUID(), text: text, date: Date(), state: state, known: [])
        message.isVoice = voice
        message.queuedAt = queued ? Date() : nil
        return OutgoingLook(message)
    }

    // S1
    func testASendingMessageIsDimmedAndConfirmedOnesAreNot() {
        XCTAssertEqual(look(.sending).opacity, OutgoingLook.dimmedOpacity)
        XCTAssertEqual(look(.sent).opacity, OutgoingLook.dimmedOpacity)
        XCTAssertLessThan(OutgoingLook.dimmedOpacity, 1)
    }

    // S3
    func testAWaitingMessageIsDimmedHasTheClockAndCanBeDeleted() {
        let waiting = look(.waiting, queued: true)
        XCTAssertEqual(waiting.opacity, OutgoingLook.dimmedOpacity)
        XCTAssertTrue(waiting.showsClock)
        XCTAssertTrue(waiting.canDelete)
        XCTAssertFalse(look(.sending).showsClock)
    }

    // S2
    func testAFailedMessageKeepsFullOpacityAndOnlyAQueuedOneCanBeDeleted() {
        XCTAssertEqual(look(.failed("No answer")).opacity, 1)
        XCTAssertTrue(look(.failed("No answer")).isFailed)
        XCTAssertFalse(look(.failed("No answer")).canDelete)
        XCTAssertTrue(look(.failed("No answer"), queued: true).canDelete)
        XCTAssertEqual(look(.failed("No answer")).failureReason, "No answer")
    }

    func testAVoiceMessageKeepsTranscribingInItsBubbleInsteadOfDimming() {
        let transcribing = look(.sending, voice: true, text: "")
        XCTAssertEqual(transcribing.opacity, 1)
        XCTAssertEqual(transcribing.accessibilityValue, "")
    }

    // S5
    func testVoiceOverReadsTheStateOfEachMessage() {
        XCTAssertEqual(look(.sending).accessibilityValue, "Sending")
        XCTAssertEqual(look(.sent).accessibilityValue, "Sending")
        XCTAssertEqual(look(.waiting).accessibilityValue, "Waiting to send")
        XCTAssertEqual(look(.failed("The Mac did not answer")).accessibilityValue, "Not sent. The Mac did not answer")
    }
}
