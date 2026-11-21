import AppKit
import Foundation
import IronPetCore

/// Backs the "Never treat as a call" list in Settings.
@MainActor
final class MicIgnoreModel: ObservableObject {
    /// An installed app found for a bundle id.
    struct AppInfo: Equatable {
        var name: String
        var url: URL
    }

    struct Row: Equatable, Identifiable {
        var bundleID: String
        var app: AppInfo?
        var id: String { bundleID }
        /// The app name, or the bundle id when the app is not installed.
        var title: String { app?.name ?? bundleID }
    }

    enum AddFailure: Equatable {
        case noIdentifier
        case rejected(MicIgnoreList.Rejection)

        var message: String {
            switch self {
            case .noIdentifier: return "This app has no identifier, so ironpet cannot ignore it."
            case .rejected(let reason): return reason.message
            }
        }
    }

    private let entries: () -> [String]
    private let save: ([String]) -> Void
    private let resolve: (String) -> AppInfo?
    private let ownBundleID: String?

    init(entries: @escaping () -> [String], save: @escaping ([String]) -> Void,
         resolve: @escaping (String) -> AppInfo? = MicIgnoreModel.installedApp,
         ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.entries = entries
        self.save = save
        self.resolve = resolve
        self.ownBundleID = ownBundleID
    }

    nonisolated static func installedApp(_ bundleID: String) -> AppInfo? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return AppInfo(name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name, url: url)
    }

    var rows: [Row] { entries().map { Row(bundleID: $0, app: resolve($0)) } }

    /// Adds an entry. Returns the reason it was refused, or nil.
    @discardableResult
    func add(_ entry: String) -> MicIgnoreList.Rejection? {
        switch MicIgnoreList.validate(entry, existing: entries(), ownBundleID: ownBundleID) {
        case .failure(let reason): return reason
        case .success(let value):
            save(entries() + [value])
            return nil
        }
    }

    /// Adds the app bundle the user picked, by its CFBundleIdentifier.
    @discardableResult
    func add(appAt url: URL) -> AddFailure? {
        guard let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty else { return .noIdentifier }
        return add(id).map(AddFailure.rejected)
    }

    func remove(_ bundleID: String) {
        save(entries().filter { $0 != bundleID })
    }
}

/// The buttons on the "record this call?" bubble.
@MainActor
enum CallOffer {
    static func recordActions(bundleID: String, name: String, ignore: MicIgnoreModel, record: @escaping () -> Void,
                              notNow: @escaping () -> Void, close: @escaping () -> Void) -> [BubbleDraft.Button] {
        [.init("record", "Record", style: .primary) {
            close()
            record()
        },
         .init("not-now", "Not now") {
            notNow()
            close()
        },
         .init("ignore", "Always ignore \(name)") {
            // The parent id, so the app's helper processes are covered. A refused entry (already ignored) still closes the offer.
            ignore.add(CallApps.parentBundleID(bundleID))
            close()
        }]
    }
}
