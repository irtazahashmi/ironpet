#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// One person ironpet can recognise by voice. Biometric data: it stays in the encrypted store on this Mac.
package struct StoredVoice: Codable, Equatable, Identifiable {
    package init(
        id: String,
        name: String,
        centroid: [Float],
        seconds: Double,
        confirmedMeetings: Int,
        created: Date,
        updated: Date,
        modelId: String
    ) {
        self.id = id
        self.name = name
        self.centroid = centroid
        self.seconds = seconds
        self.confirmedMeetings = confirmedMeetings
        self.created = created
        self.updated = updated
        self.modelId = modelId
    }

    package var id: String
    package var name: String
    /// Unit length, 256 floats.
    package var centroid: [Float]
    package var seconds: Double
    package var confirmedMeetings: Int
    package var created: Date
    package var updated: Date
    package var modelId: String
}

/// The voices ironpet has been taught, in its own file in Application Support. The file is AES-GCM encrypted with a key
/// in the Keychain, so it is useless when copied off the Mac, and it holds no audio and no transcript text.
package final class VoiceStore {
    /// The embedding model the centroids belong to. A different id makes every stored centroid meaningless.
    package static let currentModelId = "fluidaudio-offline-wespeaker-256-v1"

    package static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent(Paths.isIsolated ? "IronPet-test" : "IronPet", isDirectory: true)
        return folder.appendingPathComponent("voices.enc")
    }()

    /// A store whose key never loads, for owners `AppDelegate` has not wired yet and for tests that do not teach voices.
    package static var unwired: VoiceStore { VoiceStore(url: defaultURL, key: { nil }) }

    private let url: URL
    private let key: () -> SymmetricKey?
    private let lock = NSLock()
    package let modelId: String

    package init(url: URL, key: @escaping () -> SymmetricKey?, modelId: String = VoiceStore.currentModelId) {
        self.url = url
        self.key = key
        self.modelId = modelId
    }

    /// Voices from the current embedding model. A store written by another model is ignored, and removed on the next write.
    package func voices() -> [StoredVoice] {
        lock.lock()
        defer { lock.unlock() }
        return (read() ?? []).filter { $0.modelId == modelId }
    }

    /// True when a store file exists, readable or not. Settings uses it to keep "Forget all voices" available for a file that cannot be read.
    package var hasFile: Bool { FileManager.default.fileExists(atPath: url.path) }

    package var candidates: [VoiceCandidate] {
        voices().map { VoiceCandidate(id: $0.id, name: $0.name, centroid: $0.centroid) }
    }

    /// Adds `embedding` to the person called `name`, or creates them. Clusters with less than the minimum speech do nothing.
    /// `meetingConfirmed` counts the meeting once for this person. Returns the voice, or nil when nothing was stored.
    @discardableResult
    package func enroll(name: String, embedding: [Float], seconds: Double, meetingConfirmed: Bool = true, now: Date = Date()) -> StoredVoice? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, seconds >= SpeakerThresholds.minEnrollSeconds, !embedding.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let stored = read() else {
            NSLog("ironpet: the voice store cannot be read, so it is left as it is. Forget all voices to start again.")
            return nil
        }
        var all = stored.filter { $0.modelId == modelId }
        let unit = SpeakerMatcher.normalized(embedding)
        var voice: StoredVoice
        if let index = all.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            voice = all[index]
            voice.centroid = SpeakerMatcher.merge(voice.centroid, oldSeconds: voice.seconds, unit, newSeconds: seconds)
            voice.seconds += seconds
            if meetingConfirmed { voice.confirmedMeetings += 1 }
            voice.updated = now
            all[index] = voice
        } else {
            voice = StoredVoice(id: UUID().uuidString, name: name, centroid: unit, seconds: seconds,
                                confirmedMeetings: meetingConfirmed ? 1 : 0, created: now, updated: now, modelId: modelId)
            all.append(voice)
        }
        write(all)
        return voice
    }

    package func forget(id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let stored = read() else {
            NSLog("ironpet: the voice store cannot be read, so no voice was forgotten. Forget all voices deletes the file.")
            return
        }
        write(stored.filter { $0.id != id && $0.modelId == modelId })
    }

    /// Why `rename` changed nothing.
    package enum RenameError: Error, Equatable {
        case emptyName
        case nameTaken
        case notFound
        /// The file cannot be read or written, so it is left as it is.
        case unavailable
    }

    /// Gives the voice a new name. Only the name changes: the centroid, speech seconds and meeting count stay, and the
    /// store is sealed again with the same key. Returns the name the voice had.
    @discardableResult
    package func rename(id: String, to newName: String) throws -> String {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RenameError.emptyName }
        lock.lock()
        defer { lock.unlock() }
        guard let stored = read() else { throw RenameError.unavailable }
        var all = stored.filter { $0.modelId == modelId }
        guard let index = all.firstIndex(where: { $0.id == id }) else { throw RenameError.notFound }
        // `enroll` matches names without regard to case, so a case-only difference from another voice is a clash too.
        guard !all.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw RenameError.nameTaken }
        let old = all[index].name
        all[index].name = name
        guard write(all) else { throw RenameError.unavailable }
        return old
    }

    /// Deletes the file, so nothing is left to recover.
    package func forgetAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: File

    /// Nil when a file exists but cannot be decrypted or decoded, so a caller never overwrites it with a shorter list.
    private func read() -> [StoredVoice]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let key = key(), let data = try? Data(contentsOf: url),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return try? JSONDecoder.iso.decode([StoredVoice].self, from: plain)
    }

    @discardableResult
    private func write(_ voices: [StoredVoice]) -> Bool {
        if voices.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        guard let key = key(), let plain = try? JSONEncoder.iso.encode(voices),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else {
            NSLog("ironpet: could not encrypt the voice store")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sealed.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            NSLog("ironpet: could not write the voice store: \(error)")
            return false
        }
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// The store's AES key, created on first use and kept in the secret store (service `ironpet.voiceprints`).
package struct VoiceStoreKey: Sendable {
    package init(store: SecretStore) {
        self.store = store
    }

    package static let service = "ironpet.voiceprints"
    package static let account = "store-key"
    /// An automated run must never wait on a Keychain dialog, so `--test-mode` keeps a key for the process only.
    nonisolated(unsafe) private static var processKey: SymmetricKey?

    package var store: SecretStore

    package func load() -> SymmetricKey? {
        if CommandLine.arguments.contains("--test-mode") {
            if Self.processKey == nil { Self.processKey = SymmetricKey(size: .bits256) }
            return Self.processKey
        }
        if let data = try? store.get(service: Self.service, account: Self.account), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let fresh = SymmetricKey(size: .bits256)
        guard (try? store.set(fresh.withUnsafeBytes { Data($0) }, service: Self.service, account: Self.account)) != nil else { return nil }
        return fresh
    }
}
