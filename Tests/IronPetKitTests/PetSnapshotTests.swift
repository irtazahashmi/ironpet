import IronPetKit
import XCTest

final class PetMoodLabelTests: XCTestCase {
    func testKnownMoods() {
        XCTAssertEqual(PetMoodLabel.text("needsInput"), "Needs you")
        XCTAssertEqual(PetMoodLabel.text("attentive"), "Watching")
        XCTAssertEqual(PetMoodLabel.text("idle"), "Idle")
        XCTAssertEqual(PetMoodLabel.text("something-new"), "Idle")
    }

    func testNeedsAttention() {
        XCTAssertTrue(PetMoodLabel.needsAttention("needsInput"))
        XCTAssertTrue(PetMoodLabel.needsAttention("failed"))
        XCTAssertTrue(PetMoodLabel.needsAttention("working"))
        XCTAssertFalse(PetMoodLabel.needsAttention("idle"))
        XCTAssertFalse(PetMoodLabel.needsAttention("sleeping"))
    }
}

final class PetSnapshotStoreTests: XCTestCase {
    override func tearDown() {
        PetSnapshotStore.clear()
    }

    func testRoundTrip() throws {
        let snapshot = PetSnapshot(name: "Ghost", mood: "needsInput", badge: 3, updated: Date(timeIntervalSince1970: 1_700_000_000))
        PetSnapshotStore.save(snapshot)
        let loaded = try XCTUnwrap(PetSnapshotStore.load())
        XCTAssertEqual(loaded.name, "Ghost")
        XCTAssertEqual(loaded.mood, "needsInput")
        XCTAssertEqual(loaded.badge, 3)
        XCTAssertEqual(loaded.moodLabel, "Needs you")
        XCTAssertTrue(loaded.needsAttention)
    }

    func testBadgeAloneNeedsAttention() {
        XCTAssertTrue(PetSnapshot(name: "Ghost", mood: "idle", badge: 1).needsAttention)
        XCTAssertFalse(PetSnapshot(name: "Ghost", mood: "idle", badge: 0).needsAttention)
    }

    func testClearRemovesTheSnapshot() {
        PetSnapshotStore.save(PetSnapshot(name: "Ghost", mood: "idle", badge: 0))
        PetSnapshotStore.clear()
        XCTAssertNil(PetSnapshotStore.load())
    }
}
