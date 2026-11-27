import XCTest
@testable import IronPetCore

/// The numbers that used to be fixed in code and are now in config.json: the defaults are the old values, and out-of-range values are clamped.
final class FixedNumbersConfigTests: XCTestCase {
    func testTheDefaultsAreTheValuesThatWereFixedInCode() {
        let config = Config()
        XCTAssertEqual(config.memory.recallBytesMe, 4_000)
        XCTAssertEqual(config.memory.recallBytesProject, 6_000)
        XCTAssertEqual(config.memory.recallBytesPeople, 2_000)
        XCTAssertEqual(config.memory.digestMinutes, 60)
        XCTAssertFalse(config.memory.learnFromScreen)
        XCTAssertEqual(config.memory.maxClaimsPerEntity, 30)
        XCTAssertEqual(config.memory.noteMaxLength, 240)
        XCTAssertEqual(config.voiceMode.silenceSeconds, 20)
        XCTAssertEqual(config.jobs.retentionDays, 30)
        XCTAssertEqual(config.automations.ownRunLimit, 50)
        XCTAssertEqual(config.automations.keptThreads, 50)
        XCTAssertEqual(config.automations.runTimeoutSeconds, 900)
        XCTAssertEqual(config.meetings.transcriptCharacters, 300_000)
    }

    func testOutOfRangeValuesAreClampedWhenSanitized() {
        var config = Config()
        config.memory.recallBytesMe = 1
        config.memory.recallBytesProject = 10_000_000
        config.memory.digestMinutes = 0
        config.memory.maxClaimsPerEntity = 0
        config.memory.noteMaxLength = 10_000
        config.voiceMode.silenceSeconds = 0
        config.jobs.retentionDays = 0
        config.automations.ownRunLimit = 0
        config.automations.keptThreads = 100_000
        config.automations.runTimeoutSeconds = 1
        config.meetings.transcriptCharacters = 1
        let clean = config.sanitized()
        XCTAssertEqual(clean.memory.recallBytesMe, Config.Memory.recallBytesRange.lowerBound)
        XCTAssertEqual(clean.memory.recallBytesProject, Config.Memory.recallBytesRange.upperBound)
        XCTAssertEqual(clean.memory.digestMinutes, Config.Memory.digestMinutesRange.lowerBound)
        XCTAssertEqual(clean.memory.maxClaimsPerEntity, Config.Memory.maxClaimsPerEntityRange.lowerBound)
        XCTAssertEqual(clean.memory.noteMaxLength, Config.Memory.noteMaxLengthRange.upperBound)
        XCTAssertEqual(clean.voiceMode.silenceSeconds, Config.VoiceMode.silenceRange.lowerBound)
        XCTAssertEqual(clean.jobs.retentionDays, Config.Jobs.retentionDaysRange.lowerBound)
        XCTAssertEqual(clean.automations.ownRunLimit, Config.Automations.ownRunLimitRange.lowerBound)
        XCTAssertEqual(clean.automations.keptThreads, Config.Automations.keptThreadsRange.upperBound)
        XCTAssertEqual(clean.automations.runTimeoutSeconds, Config.Automations.runTimeoutSecondsRange.lowerBound)
        XCTAssertEqual(clean.meetings.transcriptCharacters, Config.Meetings.transcriptCharactersRange.lowerBound)
    }

    @MainActor
    func testTheRunningAppReadsTheConfiguredValues() {
        let saved = ConfigStore.shared.config
        defer { ConfigStore.shared.usePreview(saved) }
        var config = saved
        config.memory.recallBytesMe = 1_000
        config.automations.ownRunLimit = 7
        config.automations.keptThreads = 9
        config.jobs.retentionDays = 3
        ConfigStore.shared.usePreview(config)
        XCTAssertEqual(MemoryPreamble.budget[.me], 1_000)
        XCTAssertEqual(AutomationSession.ownRunLimit, 7)
        XCTAssertEqual(AutomationSession.keptThreads, 9)
        XCTAssertEqual(JobService.retention, 3 * 86_400)
    }
}
