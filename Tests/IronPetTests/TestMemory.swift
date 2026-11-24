import Foundation
@testable import IronPet
@testable import IronPetCore

/// Points Ghost's memory and its editable prompts at one temp folder for the rest of the test run, so no test reads or writes
/// `~/.ironpet/memory` or `~/.ironpet/prompts`. Every suite that starts a chat turn or an agent session calls it in setUp;
/// `ZMemoryIsolationTests` fails when one is missed.
enum TestMemory {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ironpet-test-memory-\(ProcessInfo.processInfo.processIdentifier)/memory")

    static let promptDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ironpet-test-memory-\(ProcessInfo.processInfo.processIdentifier)/prompts")

    static func isolate() {
        FileMemoryStore.directory = directory
        PromptStore.directory = promptDirectory
    }
}
