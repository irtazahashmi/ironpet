import XCTest
@testable import IronPetCore

final class UpdatePolicyTests: XCTestCase {
    private typealias Activity = UpdatePolicy.Activity

    // S4: a build from scripts/install.sh never updates.
    func testDevBuildHasUpdatesOff() {
        let dev = AppVersion(version: "0.1.2", isDev: true)
        XCTAssertNotNil(UpdatePolicy.disabledReason(version: dev))
        XCTAssertTrue(UpdatePolicy.disabledReason(version: dev)?.contains("dev builds") == true)
    }

    func testReleaseBuildHasUpdatesOn() {
        XCTAssertNil(UpdatePolicy.disabledReason(version: AppVersion(version: "0.1.2")))
    }

    func testDebugFeedOverrideTurnsUpdatesOnForADevBuild() {
        let dev = AppVersion(version: "0.1.2", isDev: true)
        XCTAssertNil(UpdatePolicy.disabledReason(version: dev, overrideFeed: URL(string: "http://127.0.0.1:8000/appcast.xml")))
    }

    func testBuildWithoutAPublicKeyHasUpdatesOff() {
        XCTAssertNotNil(UpdatePolicy.disabledReason(version: AppVersion(version: "0.1.2"), hasPublicKey: false))
    }

    // S2: the deferral gate.
    func testIdleAppInstallsAtOnce() {
        XCTAssertNil(UpdatePolicy.busyReason(Activity()))
        XCTAssertTrue(UpdatePolicy.mayInstallNow(Activity(), userApproved: false))
    }

    func testAgentTurnHoldsTheInstall() {
        let busy = Activity(agentTurnRunning: true)
        XCTAssertEqual(UpdatePolicy.busyReason(busy), "an agent turn")
        XCTAssertFalse(UpdatePolicy.mayInstallNow(busy, userApproved: false))
    }

    func testVoiceRecordingHoldsTheInstall() {
        let busy = Activity(voiceRecording: true)
        XCTAssertEqual(UpdatePolicy.busyReason(busy), "a voice recording")
        XCTAssertFalse(UpdatePolicy.mayInstallNow(busy, userApproved: false))
    }

    func testMeetingRecordingHoldsTheInstallAndIsNamedFirst() {
        let busy = Activity(agentTurnRunning: true, voiceRecording: true, meetingRecording: true)
        XCTAssertEqual(UpdatePolicy.busyReason(busy), "a meeting recording")
        XCTAssertFalse(UpdatePolicy.mayInstallNow(busy, userApproved: false))
    }

    func testAClickInstallsEvenWhileBusy() {
        XCTAssertTrue(UpdatePolicy.mayInstallNow(Activity(agentTurnRunning: true, meetingRecording: true), userApproved: true))
    }

    // S5: the downgrade guard.
    func testUpdateWithOlderSchemaIsRefusedWithAMessage() {
        let message = UpdatePolicy.downgradeRefusal(updateSchema: 12, localSchema: 14, updateVersion: "0.2.0")
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("0.2.0") == true)
        XCTAssertTrue(message?.contains("12") == true && message?.contains("14") == true)
        XCTAssertTrue(message?.contains("untouched") == true)
    }

    func testUpdateWithSameOrNewerSchemaIsAllowed() {
        XCTAssertNil(UpdatePolicy.downgradeRefusal(updateSchema: 14, localSchema: 14, updateVersion: "0.2.0"))
        XCTAssertNil(UpdatePolicy.downgradeRefusal(updateSchema: 15, localSchema: 14, updateVersion: "0.2.0"))
    }

    func testUpdateThatDoesNotSayItsSchemaIsAllowed() {
        XCTAssertNil(UpdatePolicy.downgradeRefusal(updateSchema: nil, localSchema: 14, updateVersion: "0.2.0"))
    }

    func testLatestSchemaVersionIsTheHighestMigration() {
        XCTAssertEqual(AppMigrations.latestVersion, AppMigrations.all.map(\.version).max())
        XCTAssertGreaterThan(AppMigrations.latestVersion, 0)
    }

    func testUpdatesConfigDefaultsAndRoundTrip() throws {
        let defaults = Config().updates
        XCTAssertTrue(defaults.checkAutomatically)
        XCTAssertTrue(defaults.installAutomatically)
        let data = try JSONEncoder().encode(Config(updates: .init(checkAutomatically: false, installAutomatically: false)))
        let back = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(back.updates, .init(checkAutomatically: false, installAutomatically: false))
    }
}
