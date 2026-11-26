import CryptoKit
import Foundation
import IronPetKit

/// What the phone keeps of the chat between launches: the newest page the Mac answered, the ETag it answered with, and whether older
/// messages exist. The ETag belongs to exactly this page, so a `304` for it means the saved page is still the Mac's chat.
struct SavedChat: Codable, Equatable {
    var etag: String?
    var snapshot: RemoteChatSnapshot
    var hasOlderHistory: Bool
}

protocol ChatCaching: AnyObject {
    func load() -> SavedChat?
    func save(_ chat: SavedChat)
}

/// One JSON file per pairing in the app's own Application Support folder: not in backups, file-protected, like the outbox.
final class FileChatCache: ChatCaching {
    private let url: URL

    init(url: URL) { self.url = url }

    private static var folder: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    /// The cache for one pairing and one agent. The file name carries a hash of the device token, so a chat saved for one Mac is never shown
    /// for another, and agent 1 keeps the name it always had. Files of earlier pairings are deleted, and those of this pairing's other agents stay.
    static func forToken(_ token: String?, agentId: String? = nil) -> FileChatCache {
        let tokenPart = hash(token)
        let name = prefix + tokenPart + (agentId.map { "-" + hash($0) } ?? "") + ".json"
        for old in files() where old.hasPrefix(prefix) && !old.hasPrefix(prefix + tokenPart) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
        return FileChatCache(url: folder.appendingPathComponent(name))
    }

    /// Deletes every saved chat. Called when the Mac forgets the device or the token stops working.
    static func clearAll() {
        for old in files() { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
    }

    private static let prefix = "chat-"

    private static func hash(_ text: String?) -> String {
        SHA256.hash(data: Data((text ?? "").utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func files() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasPrefix(prefix) } ?? []
    }

    func load() -> SavedChat? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(SavedChat.self, from: data)
    }

    func save(_ chat: SavedChat) {
        guard let data = try? Self.encoder.encode(chat) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = url
        try? excluded.setResourceValues(values)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Keeps the saved chat in memory. Tests use it to stand for a relaunch.
final class MemoryChatCache: ChatCaching {
    private(set) var saved: SavedChat?
    init(_ saved: SavedChat? = nil) { self.saved = saved }
    func load() -> SavedChat? { saved }
    func save(_ chat: SavedChat) { saved = chat }
}
