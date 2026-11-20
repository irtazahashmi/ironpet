import XCTest
@testable import IronPetKit

final class AtlasTests: XCTestCase {
    func testTheGhostSheetCutsAllThirteenRowsAndSixteenLookFrames() throws {
        let atlas = try XCTUnwrap(Atlas.load(data: TestSheets.png(height: 2704)))
        XCTAssertEqual(atlas.rows.count, 13)
        XCTAssertEqual(atlas.look.count, 16)
        XCTAssertEqual(atlas.rows[0].count, 8)
        XCTAssertTrue(atlas.has(.drinking))
        XCTAssertTrue(atlas.has(.stretching))
        // Every frame is the cell it was cut from: row 5 is the failed row.
        let frame = try XCTUnwrap(atlas.frame(.failed, 2))
        XCTAssertEqual(frame.width, 192)
        XCTAssertEqual(frame.height, 208)
        let color = TestSheets.center(of: frame)
        let expected = TestSheets.color(row: 5, column: 2)
        XCTAssertEqual([color.r, color.g, color.b], [expected.r, expected.g, expected.b])
    }

    func testACodexSheetHasNoDrinkingOrStretchingRows() throws {
        let atlas = try XCTUnwrap(Atlas.load(data: TestSheets.png(height: 2288)))
        XCTAssertEqual(atlas.rows.count, 11)
        XCTAssertFalse(atlas.has(.drinking))
        XCTAssertFalse(atlas.has(.stretching))
        XCTAssertTrue(atlas.has(.waving))
        XCTAssertEqual(atlas.look.count, 16)
    }

    func testASheetOfAnotherSizeIsNotAnAtlas() {
        XCTAssertNil(Atlas.load(data: TestSheets.png(height: 2000)))
        XCTAssertNil(Atlas.load(data: TestSheets.png(height: 2704, width: 1500)))
        XCTAssertNil(Atlas.load(data: Data("not an image".utf8)))
        XCTAssertFalse(Atlas.isValid(width: 1536, height: 2000))
        XCTAssertTrue(Atlas.isValid(width: 1536, height: 2288))
    }

    func testAMoodPlaysItsRowAndASheetWithoutTheRowPlaysWaving() throws {
        XCTAssertEqual(PetAnimation.row(forMood: "failed").index, 5)
        XCTAssertEqual(PetAnimation.row(forMood: "working").index, 7)
        XCTAssertEqual(PetAnimation.row(forMood: "needsInput").index, 6)
        XCTAssertEqual(PetAnimation.row(forMood: "something new").index, 0)
        let codex = try XCTUnwrap(Atlas.load(data: TestSheets.png(height: 2288)))
        let ghost = try XCTUnwrap(Atlas.load(data: TestSheets.png(height: 2704)))
        XCTAssertEqual(PetAnimation.row(forMood: "drinking", in: codex), .waving)
        XCTAssertEqual(PetAnimation.row(forMood: "drinking", in: ghost), .drinking)
        XCTAssertEqual(PetAnimation.row(forMood: "failed", in: codex), .failed)
    }
}

final class SpriteTimelineTests: XCTestCase {
    func testALoopingRowRepeats() {
        let first = SpriteTimeline.position(row: .failed, elapsed: 0.01)
        XCTAssertEqual(first, .init(row: .failed, frame: 0))
        let total = AtlasRow.failed.durations.reduce(0, +)
        XCTAssertEqual(SpriteTimeline.position(row: .failed, elapsed: total + 0.01).frame, 0)
        XCTAssertEqual(SpriteTimeline.position(row: .failed, elapsed: 0.15).frame, 1)
    }

    func testAOneShotRowSettlesIntoItsFollowUpOrHoldsTheLastFrame() {
        let total = AtlasRow.jumping.durations.reduce(0, +)
        XCTAssertEqual(SpriteTimeline.position(row: .jumping, followUp: .review, elapsed: total + 0.01).row, .review)
        XCTAssertEqual(SpriteTimeline.position(row: .waving, elapsed: 30), .init(row: .waving, frame: 3))
    }
}
