import Foundation

/// Where files a user attaches to the chat land. They are copied into one folder the agent can already read, so attaching never
/// widens what the agent can see. `FolderFileIntake` is the portable half. The Mac adds image conversion in `MacFileIntake`.
package protocol FileIntake: Sendable {
    /// False for the `Unsupported` adapter, which `Platform.capabilities` reports.
    var isSupported: Bool { get }
    /// The folder attachments are copied into.
    var directory: URL { get }
    /// Copies `file` into its own folder under `directory`, keeping its name. Throws when it is missing or a folder.
    func copy(_ file: URL) throws -> URL
    /// Writes `data` under `directory` as `<8 characters>-<name>`. Only the last path component of `fileName` is used.
    func save(_ data: Data, named fileName: String) throws -> URL
    /// Removes the oldest attachment folders beyond the newest few.
    func prune()
}

extension FileIntake {
    package var isSupported: Bool { true }
}

/// Copies files into a folder with Foundation alone.
package struct FolderFileIntake: FileIntake {
    package static let keepFolders = 40
    package static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp"]

    /// Whether the agent gets `url` as an image rather than as a file.
    package static func isImageFile(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

    package var directory: URL

    package init(directory: URL) { self.directory = directory }

    package func copy(_ file: URL) throws -> URL {
        guard let copy = Self.copy(file, into: directory) else { throw CocoaError(.fileWriteUnknown) }
        return copy
    }

    package func save(_ data: Data, named fileName: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A file name only: a remote client must not choose where on this machine the file lands.
        let name = (fileName as NSString).lastPathComponent
        let url = directory.appendingPathComponent("\(UUID().uuidString.prefix(8))-" + (name.isEmpty ? "file" : name))
        try data.write(to: url)
        return url
    }

    package func prune() { Self.prune(directory) }

    package static func copy(_ file: URL, into directory: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        // One folder per attachment keeps the original file name, which the agent sees in the prompt.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = directory.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(6))")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: target)
            prune(directory)
            return target
        } catch {
            NSLog("ironpet: could not attach \(file.path): \(error)")
            return nil
        }
    }

    /// Folder names start with a timestamp, so sorting by name is oldest first.
    package static func prune(_ directory: URL, keep: Int = keepFolders) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for old in folders.sorted(by: { $0.path > $1.path }).dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}

/// Takes no files.
package struct UnsupportedFileIntake: FileIntake {
    package init() {}

    package var platform = PlatformName.current
    package var isSupported: Bool { false }
    package var directory: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ironpet-unsupported-attachments") }
    private var error: CapabilityError { .unsupported(capability: "FileIntake", platform: platform) }

    package func copy(_ file: URL) throws -> URL { throw error }
    package func save(_ data: Data, named fileName: String) throws -> URL { throw error }
    package func prune() {}
}
