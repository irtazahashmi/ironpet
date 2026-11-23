import Foundation

/// A file the phone asked to preview: a text file's first bytes, or an image.
package struct FilePreview: Equatable {
    package var data: Data
    package var contentType: String
    package var name: String
    /// True when a text file was longer than `RemoteFilePreview.maxTextBytes` and `data` holds only its start.
    package var truncated: Bool
}

/// What the phone may read through `GET /v1/files/preview`. A path is allowed only inside the folder the open chat works in. The check runs on the path after `..` and symbolic links are resolved, so a link inside a
/// folder cannot reach outside it. Key and `.env` files are refused even inside a folder, because they hold secrets and no preview needs them.
package enum RemoteFilePreview {
    /// The most bytes of a text file the route sends. A phone shows a file, it does not edit one.
    package static let maxTextBytes = 256 * 1024
    /// The most bytes of one image, the same limit as an attachment.
    package static let maxImageBytes = RemoteUploads.maxBytes

    private static let secretExtensions: Set<String> = ["pem", "key", "p12", "pfx", "keychain", "keychain-db"]
    private static let secretFolders: Set<String> = [".ssh", ".aws", ".gnupg", ".kube", ".docker", ".ironpet", "keychains"]
    private static let secretNames: Set<String> = [".netrc", ".npmrc", ".pypirc", ".git-credentials", "credentials", "credentials.json"]
    private static let secretPrefixes = ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"]

    /// The file `raw` names, if it is inside one of `roots`. Nothing about files outside a root is revealed: a missing file and an
    /// existing one are both "outside" there.
    package static func resolve(_ raw: String, roots: [String], home: String = NSHomeDirectory()) throws -> URL {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("~/") { path = home + path.dropFirst() }
        guard path.hasPrefix("/"), !path.contains("\0") else { throw RemoteFailure.invalid("a file path must be absolute") }
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let inside = roots.contains { root in
            let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
            return base != "/" && (file.path == base || file.path.hasPrefix(base + "/"))
        }
        guard inside else {
            throw RemoteFailure(status: 403, code: "forbidden", message: "the Mac only previews files inside the folders its chat works in")
        }
        // The Mac's volume ignores case, so `.ENV` and `ID_RSA` name the same files as `.env` and `id_rsa`.
        let parts = file.pathComponents.map { $0.lowercased() }
        let name = file.lastPathComponent.lowercased()
        if name.hasPrefix(".env") || secretExtensions.contains(file.pathExtension.lowercased()) || secretNames.contains(name)
            || parts.contains(where: secretFolders.contains) || secretPrefixes.contains(where: name.hasPrefix) {
            throw RemoteFailure(status: 403, code: "forbidden", message: "the Mac does not send keys or .env files to the phone")
        }
        return file
    }

    /// Reads the preview of `file`: an image up to `maxImageBytes`, or the start of a text file.
    package static func read(_ file: URL) throws -> FilePreview {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            throw RemoteFailure(status: 404, code: "not_found", message: "there is no such file on the Mac")
        }
        guard !isDirectory.boolValue else { throw RemoteFailure.invalid("this is a folder, not a file") }
        // A pipe or device inside the folder would block the read, so only regular files are opened.
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { throw unsupported }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
        guard let size else { throw RemoteFailure(status: 404, code: "not_found", message: "the Mac cannot read this file") }

        if FolderFileIntake.isImageFile(file) {
            guard size <= maxImageBytes else { throw RemoteFailure(status: 413, code: "too_large", message: "the image is too large to send to the phone") }
            guard let data = try? Data(contentsOf: file) else { throw RemoteFailure(status: 404, code: "not_found", message: "the Mac cannot read this file") }
            return FilePreview(data: data, contentType: RemoteResources.contentType(file.lastPathComponent), name: file.lastPathComponent, truncated: false)
        }

        guard let handle = try? FileHandle(forReadingFrom: file) else { throw RemoteFailure(status: 404, code: "not_found", message: "the Mac cannot read this file") }
        defer { try? handle.close() }
        var data = (try? handle.read(upToCount: maxTextBytes)) ?? Data()
        let truncated = size > data.count
        guard !data.contains(0) else { throw unsupported }
        // A cut inside a multi-byte character is not binary: drop up to three bytes of it.
        var trim = 0
        while String(data: data, encoding: .utf8) == nil, trim < 3, !data.isEmpty { data.removeLast(); trim += 1 }
        guard String(data: data, encoding: .utf8) != nil else { throw unsupported }
        return FilePreview(data: data, contentType: "text/plain; charset=utf-8", name: file.lastPathComponent, truncated: truncated)
    }

    private static var unsupported: RemoteFailure {
        RemoteFailure(status: 415, code: "unsupported", message: "the phone previews text files and images only")
    }
}
