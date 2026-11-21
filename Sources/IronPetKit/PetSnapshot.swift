import Foundation

/// Last-known pet state for the Home Screen widget and Live Activities. No tokens or endpoints.
public struct PetSnapshot: Codable, Equatable, Sendable {
    public var name: String
    public var mood: String
    public var badge: Int
    public var updated: Date

    public init(name: String, mood: String, badge: Int, updated: Date = Date()) {
        self.name = name
        self.mood = mood
        self.badge = badge
        self.updated = updated
    }

    public var moodLabel: String { PetMoodLabel.text(mood) }
    public var needsAttention: Bool { PetMoodLabel.needsAttention(mood) || badge > 0 }
}

/// Writes the snapshot into the App Group so the widget can read it. Falls back to a file under Application Support when
/// the group container is missing (simulator builds signed without the entitlement, unit tests).
public enum PetSnapshotStore {
    public static let appGroupID = "group.dev.ironpet.app"
    public static let fileName = "pet-snapshot.json"

    public static func save(_ snapshot: PetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        if let url = fileURL() {
            try? data.write(to: url, options: .atomic)
        }
        UserDefaults(suiteName: appGroupID)?.set(data, forKey: fileName)
    }

    public static func load() -> PetSnapshot? {
        if let data = UserDefaults(suiteName: appGroupID)?.data(forKey: fileName),
           let snapshot = try? JSONDecoder().decode(PetSnapshot.self, from: data) {
            return snapshot
        }
        guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PetSnapshot.self, from: data)
    }

    public static func clear() {
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: fileName)
        if let url = fileURL() { try? FileManager.default.removeItem(at: url) }
    }

    /// The group container when App Groups are available, otherwise Application Support for the host process.
    public static func fileURL() -> URL? {
        #if canImport(Darwin)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return group.appendingPathComponent(fileName)
        }
        #endif
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                          appropriateFor: nil, create: true) else { return nil }
        return support.appendingPathComponent(fileName)
    }
}
