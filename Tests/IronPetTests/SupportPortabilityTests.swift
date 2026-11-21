import Carbon
import XCTest
@testable import IronPet
@testable import IronPetCore

final class SupportPortabilityTests: XCTestCase {
    func testShortcutParsesToCarbonCodes() {
        XCTAssertEqual(Shortcut("cmd+shift+g"), Shortcut(keyCode: kVK_ANSI_G, modifiers: cmdKey | shiftKey))
        XCTAssertEqual(Shortcut("ctrl+opt+f12"), Shortcut(keyCode: kVK_F12, modifiers: controlKey | optionKey))
    }

    func testLogKeepsSubsystemAndCategory() {
        XCTAssertEqual(ChatLog.log.subsystem, "com.ironpet")
        XCTAssertEqual(ChatLog.log.category, "chat")
        XCTAssertEqual(VoiceTiming.log.subsystem, "com.ironpet")
        XCTAssertEqual(VoiceTiming.log.category, "voice")
    }

    /// Support/ must stay free of UI, Carbon and os imports so it can move into a Foundation-only target.
    func testSupportFilesImportNoPlatformUI() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try ["Sources/IronPet/Support", "Sources/IronPetCore/Support"].flatMap { folder -> [URL] in
            let dir = repo.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        }
        XCTAssertFalse(files.isEmpty)
        let banned = try NSRegularExpression(pattern: #"^import (AppKit|SwiftUI|Carbon|os)\b"#)
        for file in files {
            var guarded = false
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "#if canImport(os)" { guarded = true }
                if trimmed == "#endif" || trimmed == "#else" { guarded = false }
                let isBanned = banned.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
                XCTAssertFalse(isBanned && !guarded, "\(file.lastPathComponent) has `\(trimmed)`")
            }
        }
    }
}
