import Foundation
import Testing
@testable import IronPetCore

@Suite struct ChatPreviewRootsTests {
    private func temp(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("roots-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func settings(_ dir: URL, _ directories: [String], _ name: String = "settings.json") throws {
        let claude = dir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let json = try JSONSerialization.data(withJSONObject: ["permissions": ["additionalDirectories": directories]])
        try json.write(to: claude.appendingPathComponent(name))
    }

    @Test func claudeSettingsAddExtraFoldersAndTheFileResolves() throws {
        let home = try temp("home"), a = try temp("a"), b = try temp("b")
        try settings(home, ["/", b.path])
        let file = b.appendingPathComponent("note.md")
        try "hi".write(to: file, atomically: true, encoding: .utf8)
        let roots = ChatPreviewRoots.compute(folder: a.path, agentId: "claude", home: home.path, extraFolders: [])
        #expect(roots.contains(b.path))
        #expect(try RemoteFilePreview.resolve(file.path, roots: roots, home: home.path) == file)
    }

    @Test func projectSettingsAndRelativePathsResolveAgainstTheFolder() throws {
        let home = try temp("home"), a = try temp("a")
        try settings(a, ["../sibling", "sub"], "settings.local.json")
        let roots = ChatPreviewRoots.compute(folder: a.path, agentId: "claude", home: home.path, extraFolders: [])
        #expect(roots.contains(a.path + "/../sibling"))
        #expect(roots.contains(a.path + "/sub"))
    }

    @Test func otherAgentsIgnoreClaudeSettings() throws {
        let home = try temp("home"), a = try temp("a"), b = try temp("b")
        try settings(home, [b.path])
        let extra = try temp("extra")
        let roots = ChatPreviewRoots.compute(folder: a.path, agentId: "cursor", home: home.path, extraFolders: [extra])
        #expect(roots == [a.path, extra.path])
    }

    @Test func malformedSettingsAreIgnored() throws {
        let home = try temp("home"), a = try temp("a")
        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try "{ nope".write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        #expect(ChatPreviewRoots.compute(folder: a.path, agentId: "claude", home: home.path, extraFolders: []) == [a.path])
    }

    @Test func scratchRecentRootAndHomeAreNotRoots() throws {
        let home = try temp("home")
        try settings(home, ["/", home.path, "~"])
        let roots = ChatPreviewRoots.compute(folder: ChatSession.scratchWorkspace.path, agentId: "claude", home: home.path, extraFolders: [])
        #expect(roots.isEmpty)
    }

    @Test func ironPetExtraFoldersAreRoots() throws {
        let a = try temp("a")
        let roots = ChatPreviewRoots.compute(folder: a.path, agentId: "cursor", home: "/nonexistent")
        #expect(roots.contains(Paths.screenshots.path))
    }

    @Test func outsideFilesAreRefusedAndSecretsInExtraFoldersToo() throws {
        let a = try temp("a"), b = try temp("b"), c = try temp("c")
        let outside = c.appendingPathComponent("x.md")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        let secret = b.appendingPathComponent("x.pem")
        try "x".write(to: secret, atomically: true, encoding: .utf8)
        let env = b.appendingPathComponent(".env")
        try "x".write(to: env, atomically: true, encoding: .utf8)
        let roots = [a.path, b.path]
        do { _ = try RemoteFilePreview.resolve(outside.path, roots: roots); Issue.record("expected refusal") } catch let failure as RemoteFailure {
            #expect(failure.status == 403)
            #expect(failure.message == "the Mac only previews files inside the folders its chat works in")
        }
        for file in [secret, env] {
            do { _ = try RemoteFilePreview.resolve(file.path, roots: roots); Issue.record("expected refusal") } catch let failure as RemoteFailure {
                #expect(failure.message == "the Mac does not send keys or .env files to the phone")
            }
        }
    }
}
