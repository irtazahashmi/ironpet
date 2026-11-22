import XCTest
@testable import IronPetKit

final class ChatFilePathsTests: XCTestCase {
    private func paths(_ text: String, home: String? = nil) -> [String] { ChatFilePaths.detect(in: text, home: home).map(\.path) }

    func testDetectionLeavesTheTildeForTheMacWhenThePhoneHasNoHome() {
        XCTAssertEqual(paths("see ~/.ironpet/config.json now"), ["~/.ironpet/config.json"])
        XCTAssertEqual(paths("see ~/.ironpet/config.json now", home: "/Users/a"), ["/Users/a/.ironpet/config.json"])
    }

    func testDetectionTable() {
        let cases: [(String, [String])] = [
            ("open /Users/a/b/brief.md now", ["/Users/a/b/brief.md"]),
            ("a /tmp/x/y.txt, b", ["/tmp/x/y.txt"]),
            ("`/tmp/x/y.txt`", ["/tmp/x/y.txt"]),
            ("/Users/a/ChatSession.swift:644", ["/Users/a/ChatSession.swift"]),
            ("/tmp/my\\ dir/a\\ b.md ok", ["/tmp/my dir/a b.md"]),
            ("file:///tmp/a%20b/c.md", ["/tmp/a b/c.md"]),
            ("/tmp", []),
            ("https://example.com/a/b", []),
            ("docs/cv.md and a/b/c", []),
        ]
        for (text, expected) in cases { XCTAssertEqual(paths(text), expected, text) }
    }

    func testTheLinkCarriesThePathExactlyAndOnlyOurSchemeIsRead() throws {
        for path in ["/Users/a/b/brief.md", "/tmp/my dir/a b+c&d#e.md", "~/x/ü.txt"] {
            let url = try XCTUnwrap(ChatFilePaths.link(forPath: path))
            XCTAssertEqual(url.scheme, "ironpet-file")
            XCTAssertEqual(ChatFilePaths.path(from: url), path)
        }
        XCTAssertNil(ChatFilePaths.path(from: URL(string: "https://example.com/?path=/etc/passwd")!))
        XCTAssertNil(ChatFilePaths.path(from: URL(string: "file:///etc/passwd")!))
    }

    func testPreviewKnowsAnImageFromTextAndSaysWhenItIsCut() {
        let text = RemoteFilePreview(path: "/a/b/notes.md", contentType: "text/plain; charset=utf-8", data: Data("héllo".utf8), truncated: true)
        XCTAssertEqual(text.name, "notes.md")
        XCTAssertEqual(text.text, "héllo")
        XCTAssertFalse(text.isImage)
        let image = RemoteFilePreview(path: "/a/shot.png", contentType: "image/png", data: Data([1, 2]), truncated: false)
        XCTAssertTrue(image.isImage)
        XCTAssertNil(image.text)
        XCTAssertNil(RemoteFilePreview(path: "/a/blob.bin", contentType: "application/octet-stream", data: Data([0x50, 0x4B, 0, 3]), truncated: false).text)
    }
}
