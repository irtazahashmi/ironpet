import CryptoKit
import Foundation
import IronPetKit

/// The settings, pet gallery and usage routes. The phone reads a small part of `config.json` and changes only the keys listed in
/// `allowed`. Where data goes (voice server, Telegram, hooks, the remote API itself) and the approval rules are not in the answer and
/// a patch that names them is refused with 403 before anything is saved.
@MainActor
struct RemotePhoneSettings {
    let api: IronPetAPI

    /// Keys a patch may set. Reminder items are expanded below.
    static let allowed: Set<String> = {
        var keys: Set<String> = [
            "pet.name", "pet.sprite", "reminders.paused", "reminders.idleResetMinutes", "reminders.snoozeMinutes",
            "tasks.dueReminders", "tasks.keepDoneDays", "tasks.meetingSuggestions", "welcomeBack.enabled",
            "speech.enabled", "speech.voice", "chat.background",
        ]
        for item in ["water", "stretch", "eyes"] { keys.insert("reminders.\(item).enabled"); keys.insert("reminders.\(item).minutes") }
        return keys
    }()

    /// Switches the phone can turn off and never on: they open the microphone or read the screen.
    static let offOnly: Set<String> = ["screenCapture.enabled", "meetings.enabled"]

    func get() -> [String: Any] {
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
    func patch(_ patch: [String: Any]) async throws -> [String: Any] {
        guard !patch.isEmpty else { throw RemoteFailure.invalid("the patch is empty") }
        let sprites = Set(await api.pet.pets().map(\.id))
        for (path, value) in Self.leaves(patch) {
            if Self.allowed.contains(path) {
                if path == "pet.sprite", !(value is NSNull), !sprites.contains(value as? String ?? "") {
                    throw RemoteFailure.forbidden("\"pet.sprite\" can only be a pet of the gallery; pick one with POST /v1/settings/pet")
                }
            } else if Self.offOnly.contains(path) {
                guard value is NSNull || (value as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() && !$0.boolValue }) == true else {
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
    static func leaves(_ patch: [String: Any], prefix: String = "") -> [(String, Any)] {
        var result: [(String, Any)] = []
        for (key, value) in patch {
            if let nested = value as? [String: Any], !nested.isEmpty { result += leaves(nested, prefix: prefix + key + ".") } else { result.append((prefix + key, value)) }
        }
        return result
    }

    // MARK: Pets

    /// The gallery. A pet's id is a hash of its sheet's path, so the Mac's folder names stay on the Mac.
    func pets() async -> [String: Any] {
        ["pets": RemoteWire.array(await api.pet.pets().map {
            RemotePetChoice(id: Self.opaque($0.id), name: $0.name, builtIn: $0.builtIn, selected: $0.selected)
        })]
    }

    func selectPet(_ args: [String: Any]) async throws -> [String: Any] {
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
    func usage(range: String?) throws -> [String: Any] {
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
    static func forbidden(_ message: String) -> RemoteFailure { RemoteFailure(status: 403, code: "forbidden", message: message) }
}
