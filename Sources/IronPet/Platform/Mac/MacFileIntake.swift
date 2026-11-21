import Foundation

/// Files attached with the + button or dropped on the chat. Images become PNG copies like a screenshot, through `ImageIntake`;
/// any other file is copied under `screenshots/attachments/`, which the agent can already read (that folder is passed with
/// `--add-dir`), so attaching never widens what the agent can see.
struct MacFileIntake: FileIntake {
    static let directory = ScreenCapture.directory.appendingPathComponent("attachments")
    static let keepFolders = FolderFileIntake.keepFolders

    var directory: URL { Self.directory }

    init() {}

    func copy(_ file: URL) throws -> URL { try FolderFileIntake(directory: directory).copy(file) }
    func save(_ data: Data, named fileName: String) throws -> URL { try FolderFileIntake(directory: directory).save(data, named: fileName) }
    func prune() { Self.prune() }

    static func attach(_ urls: [URL], into directory: URL = directory) -> [URL] {
        urls.flatMap { url -> [URL] in
            if ImageIntake.isImageFile(url) { return ImageIntake.save([url]) }
            return FolderFileIntake.copy(url, into: directory).map { [$0] } ?? []
        }
    }

    static func prune(_ directory: URL = directory, keep: Int = keepFolders) { FolderFileIntake.prune(directory, keep: keep) }
}
