import CryptoKit
import XCTest
@testable import IronPet
@testable import IronPetCore

final class MemoryNoteTests: XCTestCase {
    func testNoteLineRoundTripsWithItsDateAndSource() {
        let note = MemoryNote(text: "Prefers pnpm over npm.", date: "2026-11-18", source: "chat:3f2a9c1d")
        XCTAssertEqual(note.line, "- Prefers pnpm over npm. <!-- 2026-11-18 chat:3f2a9c1d -->")
        XCTAssertEqual(MemoryNote.parse(note.line), note)
    }

    func testHandWrittenLinesAreUserNotesAndOtherLinesAreNotNotes() {
        XCTAssertEqual(MemoryNote.parse("- Uses tabs"), MemoryNote(text: "Uses tabs", date: nil, source: "user"))
        XCTAssertEqual(MemoryNote.parse("* Uses tabs")?.line, "- Uses tabs")
        XCTAssertEqual(MemoryNote.parse("- Odd <!-- not a trailer -->")?.source, "user", "a comment that is not a trailer is part of the text")
        for line in ["# About me", "Workspace: /x", "", "-", "plain prose"] { XCTAssertNil(MemoryNote.parse(line), line) }
    }

    func testCleanKeepsOneLineAndRefusesSecretsAndLongText() {
        XCTAssertEqual(try MemoryNote.clean("- Prefers\npnpm  <!-- x -->").get(), "Prefers pnpm x")
        XCTAssertEqual(MemoryNote.clean("   "), .failure(.empty))
        XCTAssertEqual(MemoryNote.clean(String(repeating: "a", count: 241)), .failure(.tooLong))
        XCTAssertEqual(MemoryNote.clean("My key is sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"), .failure(.secret))
    }

    func testSectionsAppendInPlaceAndNewOnesGoAtTheEnd() {
        var document = MemoryDocument("# People\n\n## Ana\n\n- Leads payments <!-- 2026-11-01 chat:a -->\n\n## Bo\n\n- Likes Go\n")
        document.append(MemoryNote(text: "Is in Lisbon", date: "2026-11-18", source: "chat:b"), section: "ana")
        document.append(MemoryNote(text: "New here", date: "2026-11-18", source: "chat:b"), section: "Cy")
        XCTAssertEqual(document.text, """
            # People

            ## Ana

            - Leads payments <!-- 2026-11-01 chat:a -->
            - Is in Lisbon <!-- 2026-11-18 chat:b -->

            ## Bo

            - Likes Go

            ## Cy

            - New here <!-- 2026-11-18 chat:b -->

            """)
        XCTAssertEqual(document.entries.map(\.section), ["Ana", "Ana", "Bo", "Cy"])
    }

    func testRemoteURLsOfOneRepoNormalizeToOneKey() {
        for url in ["git@github.com:Owner/Repo.git", "https://github.com/Owner/Repo", "https://user@GitHub.com/Owner/Repo.git/",
                    "ssh://git@github.com:22/Owner/Repo.git"] {
            XCTAssertEqual(ProjectKey.normalizeRemote(url), "github.com/Owner/Repo", url)
        }
        XCTAssertEqual(ProjectKey.normalizeRemote("/srv/git/app.git"), "file:/srv/git/app")
        XCTAssertNil(ProjectKey.normalizeRemote("  "))
    }

    func testOriginIsReadFromTheGitConfig() {
        let config = """
            [core]
            \tbare = false
            [remote "upstream"]
            \turl = git@github.com:other/repo.git
            [remote "origin"]
            \turl = git@github.com:me/app.git
            \tfetch = +refs/heads/*:refs/remotes/origin/*
            """
        XCTAssertEqual(ProjectKey.originURL(config: config), "git@github.com:me/app.git")
        XCTAssertNil(ProjectKey.originURL(config: "[remote \"upstream\"]\n url = x"))
    }
}
