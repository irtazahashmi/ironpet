import XCTest
@testable import IronPetCore

/// The numbers that used to be fixed in code and are now in config.json, clamped like the other settings.
final class PromptLimitsConfigTests: XCTestCase {
    func testDefaultsMatchTheValuesThatWereFixedInCode() {
        let config = Config()
        XCTAssertEqual(config.memory.reflectMaxNotes, 8)
        XCTAssertEqual(config.memory.reflectMaxInputChars, 24_000)
        XCTAssertEqual(config.memory.reflectTimeoutSeconds, 180)
        XCTAssertEqual(config.jobs.turnTimeoutMinutes, 60)
    }

    func testOutOfRangeValuesAreClampedWhenSanitized() {
        var config = Config()
        config.memory.reflectMaxNotes = 0
        config.memory.reflectMaxInputChars = 10
        config.memory.reflectTimeoutSeconds = 99_999
        config.jobs.turnTimeoutMinutes = 0
        let clean = config.sanitized()
        XCTAssertEqual(clean.memory.reflectMaxNotes, Config.Memory.reflectMaxNotesRange.lowerBound)
        XCTAssertEqual(clean.memory.reflectMaxInputChars, Config.Memory.reflectMaxInputCharsRange.lowerBound)
        XCTAssertEqual(clean.memory.reflectTimeoutSeconds, Config.Memory.reflectTimeoutSecondsRange.upperBound)
        XCTAssertEqual(clean.jobs.turnTimeoutMinutes, Config.Jobs.turnTimeoutRange.lowerBound)
    }

    @MainActor
    func testTheReflectorReadsItsLimitsFromConfig() {
        let saved = ConfigStore.shared.config
        defer { ConfigStore.shared.usePreview(saved) }
        var config = saved
        config.memory.reflectMaxNotes = 3
        config.memory.reflectMaxInputChars = 5_000
        config.memory.reflectTimeoutSeconds = 45
        ConfigStore.shared.usePreview(config)
        XCTAssertEqual(MemoryReflector.maxNotes, 3)
        XCTAssertEqual(MemoryReflector.maxInput, 5_000)
        XCTAssertEqual(MemoryReflector.timeout, 45)
    }
}
