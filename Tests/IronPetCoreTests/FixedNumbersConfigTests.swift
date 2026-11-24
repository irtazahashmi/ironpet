import XCTest
@testable import IronPetCore

/// The numbers that used to be fixed in code and are now in config.json: the defaults are the old values, and out-of-range values are clamped.
final class FixedNumbersConfigTests: XCTestCase {
    func testTheDefaultsAreTheValuesThatWereFixedInCode() {
        let config = Config()
        XCTAssertEqual(config.memory.recallBytesMe, 4_000)
        XCTAssertEqual(config.memory.recallBytesProject, 6_000)
        XCTAssertEqual(config.memory.recallBytesPeople, 2_000)
        XCTAssertEqual(config.memory.sizeLimitMe, 8_000)
        XCTAssertEqual(config.memory.sizeLimitProject, 12_000)
        XCTAssertEqual(config.memory.sizeLimitPeople, 8_000)
        XCTAssertEqual(config.memory.catchUpDays, 7)
        XCTAssertEqual(config.memory.catchUpThreads, 5)
        XCTAssertEqual(config.memory.noteMaxLength, 240)
        XCTAssertEqual(config.voiceMode.idleShutdownMinutes, 10)
        XCTAssertEqual(config.voiceMode.fastModelWords, ["haiku", "flash", "mini", "fast", "lite"])
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
        config.memory.sizeLimitMe = 0
        config.memory.sizeLimitPeople = 10_000_000
        config.memory.catchUpDays = 0
        config.memory.catchUpThreads = 0
        config.memory.noteMaxLength = 10_000
        config.voiceMode.idleShutdownMinutes = 0
        config.jobs.retentionDays = 0
        config.automations.ownRunLimit = 0
        config.automations.keptThreads = 100_000
        config.automations.runTimeoutSeconds = 1
        config.meetings.transcriptCharacters = 1
        let clean = config.sanitized()
        XCTAssertEqual(clean.memory.recallBytesMe, Config.Memory.recallBytesRange.lowerBound)
        XCTAssertEqual(clean.memory.recallBytesProject, Config.Memory.recallBytesRange.upperBound)
        XCTAssertEqual(clean.memory.sizeLimitMe, Config.Memory.sizeLimitRange.lowerBound)
        XCTAssertEqual(clean.memory.sizeLimitPeople, Config.Memory.sizeLimitRange.upperBound)
        XCTAssertEqual(clean.memory.catchUpDays, Config.Memory.catchUpDaysRange.lowerBound)
        XCTAssertEqual(clean.memory.catchUpThreads, Config.Memory.catchUpThreadsRange.lowerBound)
        XCTAssertEqual(clean.memory.noteMaxLength, Config.Memory.noteMaxLengthRange.upperBound)
        XCTAssertEqual(clean.voiceMode.idleShutdownMinutes, Config.VoiceMode.idleShutdownRange.lowerBound)
        XCTAssertEqual(clean.jobs.retentionDays, Config.Jobs.retentionDaysRange.lowerBound)
        XCTAssertEqual(clean.automations.ownRunLimit, Config.Automations.ownRunLimitRange.lowerBound)
        XCTAssertEqual(clean.automations.keptThreads, Config.Automations.keptThreadsRange.upperBound)
        XCTAssertEqual(clean.automations.runTimeoutSeconds, Config.Automations.runTimeoutSecondsRange.lowerBound)
        XCTAssertEqual(clean.meetings.transcriptCharacters, Config.Meetings.transcriptCharactersRange.lowerBound)
    }

    func testFastModelWordsAreTrimmedLowercasedDeduplicatedAndCapped() {
        var config = Config()
        config.voiceMode.fastModelWords = [" Haiku ", "haiku", "", "FLASH", "   "]
        XCTAssertEqual(config.sanitized().voiceMode.fastModelWords, ["haiku", "flash"])
        config.voiceMode.fastModelWords = (0..<40).map { "word\($0)" }
        XCTAssertEqual(config.sanitized().voiceMode.fastModelWords.count, Config.VoiceMode.maxFastModelWords)
    }

    @MainActor
    func testTheRunningAppReadsTheConfiguredValues() {
        let saved = ConfigStore.shared.config
        defer { ConfigStore.shared.usePreview(saved) }
        var config = saved
        config.memory.recallBytesMe = 1_000
        config.memory.sizeLimitProject = 20_000
        config.automations.ownRunLimit = 7
        config.automations.keptThreads = 9
        config.jobs.retentionDays = 3
        ConfigStore.shared.usePreview(config)
        XCTAssertEqual(MemoryPreamble.budget[.me], 1_000)
        XCTAssertEqual(FileMemoryStore.sizeLimit[.project], 20_000)
        XCTAssertEqual(AutomationSession.ownRunLimit, 7)
        XCTAssertEqual(AutomationSession.keptThreads, 9)
        XCTAssertEqual(JobService.retention, 3 * 86_400)
    }
}
