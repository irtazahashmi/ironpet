import XCTest
@testable import IronPetCore

final class AppVersionTests: XCTestCase {
    private let release: [String: Any] = ["CFBundleShortVersionString": "0.1.2", "CFBundleVersion": "7", "IronPetGitCommit": "744b030"]

    func testReleaseLabel() {
        XCTAssertEqual(AppVersion(info: release).label, "IronPet 0.1.2 (744b030)")
    }

    func testDevBuildLabel() {
        var info = release
        info["IronPetDevBuild"] = true
        XCTAssertEqual(AppVersion(info: info).label, "IronPet 0.1.2 dev (744b030)")
    }

    func testMissingCommitLeavesItOut() {
        XCTAssertEqual(AppVersion(info: ["CFBundleShortVersionString": "0.1.2"]).label, "IronPet 0.1.2")
        XCTAssertEqual(AppVersion(info: ["CFBundleShortVersionString": "0.1.2", "IronPetGitCommit": " "]).label, "IronPet 0.1.2")
    }

    func testMissingInfoFallsBackToDev() {
        XCTAssertEqual(AppVersion(info: nil).label, "IronPet dev")
    }

    func testCopyTextHasVersionCommitAndBuild() {
        XCTAssertEqual(AppVersion(info: release).copyText, "IronPet 0.1.2 (744b030), build 7")
        XCTAssertEqual(AppVersion(info: ["CFBundleShortVersionString": "0.1.2"]).copyText, "IronPet 0.1.2")
    }
}
