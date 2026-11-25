import XCTest
@testable import IronPet
@testable import IronPetCore

@MainActor
final class UpdateControllerTests: XCTestCase {
    private let feed = [UpdateController.feedOverrideVariable: "http://127.0.0.1:8000/appcast.xml"]

    // S4: a dev build never starts Sparkle, so it cannot check or install.
    func testDevBuildNeverStartsTheUpdater() {
        let controller = UpdateController(appVersion: AppVersion(version: "0.1.2", isDev: true), publicKey: "key", environment: [:])
        controller.start(config: Config.Updates())
        guard case .off(let reason) = controller.state else { return XCTFail("expected off, got \(controller.state)") }
        XCTAssertTrue(reason.contains("dev builds"))
        XCTAssertFalse(controller.canCheck)
        controller.checkNow()
        XCTAssertEqual(controller.state, .off(reason), "Check now does nothing on a dev build")
    }

    func testBuildWithoutAPublicKeyHasUpdatesOff() {
        let controller = UpdateController(appVersion: AppVersion(version: "0.1.2"), publicKey: " ", environment: [:])
        controller.start(config: Config.Updates())
        guard case .off(let reason) = controller.state else { return XCTFail("expected off, got \(controller.state)") }
        XCTAssertTrue(reason.contains("SUPublicEDKey"))
    }

    // A release build must not let an environment variable choose its feed.
    func testReleaseBuildIgnoresTheFeedOverride() {
        let controller = UpdateController(appVersion: AppVersion(version: "0.1.2"), publicKey: "key", environment: feed)
        XCTAssertNil(controller.feedOverride)
        XCTAssertNil(controller.disabledReason)
    }

    func testDevBuildWithTheOverrideIsOnAndUsesIt() {
        let controller = UpdateController(appVersion: AppVersion(version: "0.1.2", isDev: true), publicKey: "key", environment: feed)
        XCTAssertNil(controller.disabledReason)
        XCTAssertEqual(controller.feedOverride, "http://127.0.0.1:8000/appcast.xml")
    }
}
