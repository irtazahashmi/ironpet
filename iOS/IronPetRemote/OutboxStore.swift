import CryptoKit
import Foundation
import IronPetKit

/// A typed message that has not reached the Mac yet, as it is written to disk. It holds the message text and nothing else the phone
/// knows: no token, no endpoint.
struct OutboxRecord: Codable, Equatable {
    var id: UUID
    var text: String
    /// When the user typed it. The transcript sorts and draws by it.
    var date: Date
    /// When it first started waiting. The age limit counts from here.
    var queuedAt: Date
    var replyItemID: String?
    var replySelection: String?
    /// Set when the message stopped waiting without being sent: the Mac refused it, or it waited past the age limit.
    var failure: String?

    var reply: RemoteReplyRef? { replyItemID.map { RemoteReplyRef(itemID: $0, selectionText: replySelection) } }
}

/// Where the outbox lives between launches.
protocol OutboxStoring: AnyObject {
    func load() -> [OutboxRecord]
    func save(_ records: [OutboxRecord])
}

/// One JSON file in the app's own Application Support folder. It is not in the shared app group and is left out of backups, so it
/// never reaches iCloud. A file that cannot be read counts as an empty outbox.
final class FileOutboxStore: OutboxStoring {
    private let url: URL

    init(url: URL = FileOutboxStore.defaultURL) { self.url = url }

    static var defaultURL: URL { folder.appendingPathComponent("outbox.json") }

    private static var folder: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    /// The store for one pairing. The file name carries a hash of the device token, so messages typed for one Mac never go to
    /// another after a new pairing. Files of earlier pairings are deleted.
    static func forToken(_ token: String?) -> FileOutboxStore {
        let name = "outbox-" + SHA256.hash(data: Data((token ?? "").utf8)).prefix(6).map { String(format: "%02x", $0) }.joined() + ".json"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for old in names where old.hasPrefix("outbox") && old.hasSuffix(".json") && old != name {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
        return FileOutboxStore(url: folder.appendingPathComponent(name))
    }

    func load() -> [OutboxRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([OutboxRecord].self, from: data)) ?? []
    }

    func save(_ records: [OutboxRecord]) {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if records.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? Self.encoder.encode(records) else { return }
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

/// Keeps the records in memory. Tests share one between two models to stand for a relaunch.
final class MemoryOutboxStore: OutboxStoring {
    private(set) var records: [OutboxRecord]

    init(_ records: [OutboxRecord] = []) { self.records = records }

    func load() -> [OutboxRecord] { records }
    func save(_ records: [OutboxRecord]) { self.records = records }
}
