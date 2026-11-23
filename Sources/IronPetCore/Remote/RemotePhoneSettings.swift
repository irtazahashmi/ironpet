#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import IronPetKit

/// The settings, pet gallery and usage routes. The phone reads a small part of `config.json` and changes only the keys listed in
/// `allowed`. Where data goes (voice server, Telegram, hooks, the remote API itself) and the approval rules are not in the answer and
/// a patch that names them is refused with 403 before anything is saved.
@MainActor
package struct RemotePhoneSettings {
    package init(api: IronPetAPI) {
        self.api = api
    }

    package let api: IronPetAPI

    /// Keys a patch may set. Reminder items are expanded below.
    package static let allowed: Set<String> = {
        var keys: Set<String> = [
            "pet.name", "pet.sprite", "reminders.paused", "reminders.idleResetMinutes", "reminders.snoozeMinutes",
            "tasks.dueReminders", "tasks.keepDoneDays", "tasks.meetingSuggestions", "welcomeBack.enabled",
            "speech.enabled", "speech.voice", "chat.background",
        ]
        for item in ["water", "stretch", "eyes"] { keys.insert("reminders.\(item).enabled"); keys.insert("reminders.\(item).minutes") }
        return keys
    }()

    /// Switches the phone can turn off and never on: they open the microphone or read the screen.
    package static let offOnly: Set<String> = ["screenCapture.enabled", "meetings.enabled"]

    package func get() -> [String: Any] {
        let c = api.settings.config
        let reminder = { (item: Config.Reminders.Item) in RemoteConfig.Reminder(enabled: item.enabled, minutes: item.minutes) }
        return RemoteWire.object(RemoteConfig(
            pet: .init(name: c.pet.name, sprite: nil),
            reminders: .init(paused: c.reminders.paused, water: reminder(c.reminders.water), stretch: reminder(c.reminders.stretch),
                             eyes: reminder(c.reminders.eyes), idleResetMinutes: c.reminders.idleResetMinutes, snoozeMinutes: c.reminders.snoozeMinutes),
            tasks: .init(meetingSuggestions: c.tasks.meetingSuggestions, dueReminders: c.tasks.dueReminders, keepDoneDays: c.tasks.keepDoneDays),
            welcomeBack: .init(enabled: c.welcomeBack.enabled), speech: .init(enabled: c.speech.enabled, voice: c.speech.voice),
            chat: .init(background: c.chat.background), screenCapture: .init(enabled: c.screenCapture.enabled), meetings: .init(enabled: c.meetings.enabled)))
    }

    /// A merge patch. Every key it sets is checked first, so one key that is not allowed changes nothing.
    package func patch(_ patch: [String: Any]) async throws -> [String: Any] {
        guard !patch.isEmpty else { throw RemoteFailure.invalid("the patch is empty") }
        let sprites = Set(await api.pet.pets().map(\.id))
        for (path, value) in Self.leaves(patch) {
            if Self.allowed.contains(path) {
                if path == "pet.sprite", !(value is NSNull), !sprites.contains(value as? String ?? "") {
                    throw RemoteFailure.forbidden("\"pet.sprite\" can only be a pet of the gallery; pick one with POST /v1/settings/pet")
                }
            } else if Self.offOnly.contains(path) {
                guard value is NSNull || (value as? NSNumber).map({ $0.isJSONBoolean && !$0.boolValue }) == true else {
                    throw RemoteFailure.forbidden("\"\(path)\" can only be turned off from the phone")
                }
            } else {
                throw RemoteFailure.forbidden("\"\(path)\" cannot be changed from the phone")
            }
        }
        let body = String(decoding: try JSONSerialization.data(withJSONObject: patch), as: UTF8.self)
        _ = try api.settings.patch(PatchSettingsRequest(patch: body))
        return get()
    }

    /// Every value a patch sets, with its dotted path. An object is walked, anything else is a value, so `{"voice": 1}` is the path `voice`.
    package static func leaves(_ patch: [String: Any], prefix: String = "") -> [(String, Any)] {
        var result: [(String, Any)] = []
        for (key, value) in patch {
            if let nested = value as? [String: Any], !nested.isEmpty { result += leaves(nested, prefix: prefix + key + ".") } else { result.append((prefix + key, value)) }
        }
        return result
    }

    // MARK: Background image

    /// The kind of image `data` is, from its first bytes: JPEG, PNG or HEIC. The file name and the request's content type are not trusted.
    package static func imageExtension(of data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return "jpg" }
        if head.count >= 8, head[0..<8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if head.count >= 12, String(decoding: head[4..<8], as: UTF8.self) == "ftyp",
           ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(String(decoding: head[8..<12], as: UTF8.self)) { return "heic" }
        return nil
    }

    /// Makes the image the custom chat background and returns the new settings. The size limit is the attachment limit. The Mac
    /// stores the image as the user's own pick would be stored, so the Mac and every phone show it.
    package func uploadBackground(_ data: Data) async throws -> [String: Any] {
        guard !data.isEmpty else { throw RemoteFailure.invalid("the image is empty") }
        guard data.count <= RemoteUploads.maxBytes else {
            throw RemoteFailure(status: 413, code: "too_large", message: "the image is larger than \(RemoteUploads.maxBytes) bytes")
        }
        guard let ext = Self.imageExtension(of: data) else {
            throw RemoteFailure(status: 415, code: "unsupported_type", message: "the background must be a JPEG, PNG or HEIC image")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-background-\(UUID().uuidString)")
        let file = folder.appendingPathComponent("upload.\(ext)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file)
        } catch {
            throw RemoteFailure(status: 500, code: "failed", message: "the Mac could not store the image")
        }
        try api.pet.importBackground(file)
        return get()
    }

    // MARK: Pets

    /// The gallery. A pet's id is a hash of its sheet's path, so the Mac's folder names stay on the Mac.
    package func pets() async -> [String: Any] {
        ["pets": RemoteWire.array(await api.pet.pets().map {
            RemotePetChoice(id: Self.opaque($0.id), name: $0.name, builtIn: $0.builtIn, selected: $0.selected)
        })]
    }

    package func selectPet(_ args: [String: Any]) async throws -> [String: Any] {
        guard let id = args["id"] as? String, !id.isEmpty else { throw RemoteFailure.invalid("id is missing") }
        guard let match = await api.pet.pets().first(where: { Self.opaque($0.id) == id }) else {
            throw RemoteFailure(status: 404, code: "not_found", message: "no pet with id \"\(id)\"")
        }
        try await api.pet.selectPet(SelectPetRequest(id: match.id))
        return ["selected": id]
    }

    private static func opaque(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Usage

    /// `range` is a number of days, as `7` or `7d`.
    package func usage(range: String?) throws -> [String: Any] {
        guard let usage = api.usage else { throw RemoteFailure(status: 503, code: "unavailable", message: "usage is not recorded on this Mac") }
        let text = (range ?? "7d").trimmingCharacters(in: CharacterSet(charactersIn: "dD"))
        guard let days = Int(text), (1...400).contains(days) else { throw RemoteFailure.invalid("range must be 1 to 400 days, such as 7d") }
        let summary = try usage.summary(UsageRequest(days: days))
        return RemoteWire.object(RemoteUsage(
            days: days,
            rows: summary.rows.map { RemoteUsage.Row(feature: $0.feature.rawValue, model: $0.model, currency: $0.currency, requests: $0.requests,
                                                      totalTokens: $0.totalTokens, cost: $0.cost) },
            todayCost: summary.todayCost, rangeCost: summary.rangeCost, hasCost: summary.hasCost))
    }
}

extension RemoteFailure {
    package static func forbidden(_ message: String) -> RemoteFailure { RemoteFailure(status: 403, code: "forbidden", message: message) }
}
