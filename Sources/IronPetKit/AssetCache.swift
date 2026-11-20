import CryptoKit
import Foundation

/// Files from `GET /v1/assets/<sha256>`, kept on disk under their hash. A hash never changes meaning, so a file is downloaded once.
/// The phone fetches the manifest on launch and on `assets.changed`, downloads the hashes it needs and does not have, and deletes
/// hashes the manifest no longer lists after a week.
public final class AssetCache: @unchecked Sendable {
    /// What one `sync` did.
    public struct Result: Equatable, Sendable {
        /// Asset id to hash, for the ids this cache keeps (`pet.sprite`, `chat.background`).
        public var current: [String: String]
        /// Hashes fetched from the Mac in this sync.
        public var downloaded: [String]
    }

    public static let retention: TimeInterval = 7 * 24 * 3600
    /// Ids the phone shows. The gallery sheets in the manifest are for the settings of a later phase, so they are not downloaded.
    public static let defaultIDs: Set<String> = ["pet.sprite", "chat.background"]

    public let directory: URL
    private let ids: Set<String>
    private let now: () -> Date

    public init(directory: URL, ids: Set<String> = AssetCache.defaultIDs, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.ids = ids
        self.now = now
    }

    public func url(forHash hash: String) -> URL? {
        let url = file(hash)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func data(forHash hash: String) -> Data? { url(forHash: hash).flatMap { try? Data(contentsOf: $0) } }

    private func file(_ hash: String) -> URL { directory.appendingPathComponent(hash) }

    /// Reads the manifest and downloads what is missing. A download whose bytes do not hash to the listed value, or a sprite sheet
    /// that is not an atlas, is dropped and not kept. A failure of one file does not stop the others.
    @discardableResult
    public func sync(with client: IronPetClient) async throws -> Result {
        let manifest = try await client.assetManifest()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var current: [String: String] = [:]
        var downloaded: [String] = []
        for asset in manifest where ids.contains(asset.id) {
            if url(forHash: asset.sha256) != nil {
                current[asset.id] = asset.sha256
                continue
            }
            guard let data = try? await client.downloadAsset(sha256: asset.sha256), Self.valid(data, asset) else { continue }
            guard (try? data.write(to: file(asset.sha256), options: .atomic)) != nil else { continue }
            current[asset.id] = asset.sha256
            downloaded.append(asset.sha256)
        }
        prune(listed: Set(manifest.map(\.sha256)))
        return Result(current: current, downloaded: downloaded)
    }

    private static func valid(_ data: Data, _ asset: RemoteAsset) -> Bool {
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == asset.sha256 else { return false }
        return asset.kind != "spritesheet" || Atlas.load(data: data) != nil
    }

    /// Keeps listed files (and marks them seen) and deletes the others once they have been unlisted for a week.
    func prune(listed: Set<String>) {
        let at = now()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files {
            if listed.contains(url.lastPathComponent) {
                try? FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: url.path)
                continue
            }
            let seen = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? at
            if at.timeIntervalSince(seen) > Self.retention { try? FileManager.default.removeItem(at: url) }
        }
    }
}
