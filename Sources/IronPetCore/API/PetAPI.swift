#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import IronPetKit

package struct PetState: Codable, Equatable {
    package init(mood: String, badge: Int) {
        self.mood = mood
        self.badge = badge
    }

    /// The mood the pet shows, such as `idle`, `working`, `needsInput`.
    package var mood: String
    /// How many sessions and alerts share the mood.
    package var badge: Int
}

/// The user's macOS accent colour as `#RRGGBB`, for light and dark mode.
package struct PetAccent: Equatable {
    package init(light: String, dark: String) {
        self.light = light
        self.dark = dark
    }

    package var light: String
    package var dark: String
}

package struct PetInfo: Codable, Equatable, Identifiable {
    package init(id: String, name: String, builtIn: Bool, selected: Bool) {
        self.id = id
        self.name = name
        self.builtIn = builtIn
        self.selected = selected
    }

    /// The sheet's standardized file path. Pass it back to `selectPet`.
    package var id: String
    package var name: String
    package var builtIn: Bool
    package var selected: Bool
}

package struct SelectPetRequest: Codable, Equatable {
    package init(id: String) {
        self.id = id
    }

    package var id: String
}

package struct PerformTrickRequest: Codable, Equatable {
    package init(name: String) {
        self.name = name
    }

    /// One of the names `tricks()` lists, such as "Wave".
    package var name: String
}

package struct BackgroundInfo: Codable, Equatable, Identifiable {
    package init(id: String, name: String, selected: Bool) {
        self.id = id
        self.name = name
        self.selected = selected
    }

    /// `default`, a built-in id such as `dusk`, or `custom`.
    package var id: String
    package var name: String
    package var selected: Bool
}

package struct SelectBackgroundRequest: Codable, Equatable {
    package init(id: String) {
        self.id = id
    }

    package var id: String
}

package enum AssetKind: String, Codable {
    case sprite, background
}

/// One file a client can download and cache. Compare `sha256` with the copy it holds to know whether it is stale.
package struct AssetEntry: Codable, Equatable, Identifiable {
    package init(id: String, kind: AssetKind, name: String, sha256: String, bytes: Int, width: Int? = nil, height: Int? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.sha256 = sha256
        self.bytes = bytes
        self.width = width
        self.height = height
    }

    /// `sprite:<file name>` or `background:<file name>` for a file of its own. `pet.sprite` and `chat.background` name the sheet and the image in use now.
    package var id: String
    package var kind: AssetKind
    package var name: String
    package var sha256: String
    package var bytes: Int
    /// Pixel size, for a sprite sheet.
    package var width: Int? = nil
    package var height: Int? = nil
}

package struct AssetManifest: Codable, Equatable {
    package init(assets: [AssetEntry]) {
        self.assets = assets
    }

    package var assets: [AssetEntry]
}

/// The pet and how the app looks: the pet's mood and tricks, the gallery of sprite sheets, chat backgrounds, and a manifest of
/// the files behind them with content hashes, so a client can download each one once and keep it.
@MainActor
package final class PetAPI {
    private let settings: SettingsAPI
    private let assets: PetAssets
    private var assetSignature: [String]?
    package weak var events: APIEventBus?

    /// The running app's pet API, for the Settings pages. The Mac target sets it to `PetAPI.onThisMac()` at launch, and `IronPetAPI` then sets it to its own, so there is one instance.
    package static var live = PetAPI(settings: .live, assets: UnsupportedPetAssets())

    /// The pet's current mood and badge. The pet window supplies it.
    package var stateProvider: () -> PetState = { PetState(mood: "idle", badge: 0) }
    /// Plays a trick by name. The pet window supplies it. Returns false for a name it does not know.
    package var trickHandler: (String) -> Bool = { _ in false }
    /// The Mac's accent colour. Nil when the user has not picked one (macOS multicolour), so a client keeps its own default.
    /// The Mac target supplies it, because reading it needs AppKit.
    package var accentProvider: () -> PetAccent? = { nil }
    /// The tricks the pet knows, in menu order.
    package var trickNames: () -> [String] = { [] }

    package init(settings: SettingsAPI, assets: PetAssets) {
        self.settings = settings
        self.assets = assets
    }

    // MARK: Mood and tricks

    package func state() -> PetState { stateProvider() }

    package func tricks() -> [String] { trickNames() }

    package func accent() -> PetAccent? { accentProvider() }

    package func perform(_ request: PerformTrickRequest) throws {
        guard trickHandler(request.name) else { throw APIError.notFound("the pet does not know \"\(request.name)\"") }
    }

    // MARK: Gallery

    /// The pets in the gallery, built-in ones first. Reads the sheets off the main thread, so it can take a moment.
    package func pets() async -> [PetInfo] {
        let (assets, current) = (assets, settings.config.pet.sprite)
        let entries = await Task.detached { (try? assets.entries(current: current)) ?? [] }.value
        let selected = assets.selectedID(in: entries, sprite: current)
        return entries.map { entry in
            PetInfo(id: entry.id, name: entry.name, builtIn: assets.builtInNames.contains(entry.url.deletingPathExtension().lastPathComponent.lowercased()),
                    selected: entry.id == selected)
        }
    }

    package func selectPet(_ request: SelectPetRequest) async throws {
        let (assets, current) = (assets, settings.config.pet.sprite)
        let entries = await Task.detached { (try? assets.entries(current: current)) ?? [] }.value
        guard let entry = entries.first(where: { $0.id == request.id }) else { throw APIError.notFound("no pet with id \"\(request.id)\"") }
        select(entry)
    }

    /// Makes a gallery entry the pet.
    package func select(_ entry: PetEntry) {
        let before = settings.config.pet.sprite
        settings.update { [assets] in assets.select(entry, in: &$0) }
        if settings.config.pet.sprite != before { events?.publish(.assetsChanged) }
    }

    /// Copies a sprite sheet into the pet library and makes it the pet.
    @discardableResult
    package func importPet(_ source: URL) throws -> PetEntry {
        let entry: PetEntry
        do { entry = try assets.importSheet(source) } catch { throw APIError.invalid(error.localizedDescription) }
        select(entry)
        checkAssets()
        return entry
    }

    // MARK: Backgrounds

    package func backgroundList() -> [BackgroundInfo] {
        let current = settings.config.chat.background
        var list = [BackgroundInfo(id: ChatBackgrounds.defaultID, name: "Default", selected: current == ChatBackgrounds.defaultID)]
        list += ChatBackgrounds.builtIns.map { BackgroundInfo(id: $0.id, name: $0.name, selected: current == $0.id) }
        list.append(BackgroundInfo(id: ChatBackgrounds.customID, name: "Custom image", selected: current == ChatBackgrounds.customID))
        return list
    }

    package func selectBackground(_ request: SelectBackgroundRequest) throws {
        if request.id == ChatBackgrounds.customID {
            guard settings.config.chat.customImage != nil else { throw APIError.invalid("no custom image has been added yet") }
        } else if request.id != ChatBackgrounds.defaultID, ChatBackgrounds.builtIn(request.id) == nil {
            throw APIError.notFound("no background with id \"\(request.id)\"")
        }
        let before = settings.config.chat.background
        settings.update { $0.chat.background = request.id }
        if request.id != before, request.id == ChatBackgrounds.customID || before == ChatBackgrounds.customID { events?.publish(.assetsChanged) }
    }

    /// Copies an image into the backgrounds folder and makes it the chat background. The previous custom image is removed.
    package func importBackground(_ source: URL) throws {
        do {
            let name = try assets.importBackground(from: source, replacing: settings.config.chat.customImage)
            settings.update { $0.chat.background = ChatBackgrounds.customID; $0.chat.customImage = name }
            checkAssets()
        } catch {
            throw APIError.invalid(error.localizedDescription)
        }
    }

    // MARK: Assets

    /// Every file a client can download: the pet sheets, the sheet the pet shows now (`pet.sprite`) and the custom background
    /// image. A sheet that is not in the atlas layout is left out, as the gallery skips it. The built-in backgrounds are drawn
    /// from their ids, so they have no file.
    package func manifest() async -> AssetManifest {
        AssetManifest(assets: await resolvedAssets().map(\.entry))
    }

    /// The bytes of an asset from `manifest`.
    package func assetData(_ id: String) async throws -> Data {
        guard let asset = await resolvedAssets().first(where: { $0.entry.id == id }) else { throw APIError.notFound("no asset with id \"\(id)\"") }
        return try Self.read(asset.url)
    }

    /// The bytes of the asset with this content hash. Two ids can share one hash (`pet.sprite` and the gallery entry it is).
    package func assetData(sha256: String) async throws -> (entry: AssetEntry, data: Data) {
        guard let asset = await resolvedAssets().first(where: { $0.entry.sha256 == sha256 }) else { throw APIError.notFound("no asset with this hash") }
        return (asset.entry, try Self.read(asset.url))
    }

    nonisolated private static func read(_ url: URL) throws -> Data {
        guard let data = try? Data(contentsOf: url) else { throw APIError.failed("the asset could not be read") }
        return data
    }

    private struct ResolvedAsset { var entry: AssetEntry; var url: URL }

    /// The hashes of every sheet cost a read of each file, and a phone asks for the manifest on each mood change. The result is kept
    /// until a file's name, size or date changes, or the pet or background setting does.
    private var resolvedCache: (key: [String], assets: [ResolvedAsset])?

    private func resolvedAssets() async -> [ResolvedAsset] {
        let (folders, custom, sprite) = (assets, settings.config.chat.customImage, settings.config.pet.sprite)
        let spriteFile = (sprite.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
            .flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) }
        let key = signature() + PetFolderSignature(folder: Paths.petDir).items
            + ["sprite|\(sprite ?? "")|\(spriteFile?.fileSize ?? 0)|\(spriteFile?.contentModificationDate?.timeIntervalSince1970 ?? 0)", "custom|\(custom ?? "")"]
        if let cached = resolvedCache, cached.key == key { return cached.assets }
        let assets = await Task.detached { () -> [ResolvedAsset] in
            var byName: [String: URL] = [:]
            let sheets = folders.sheetFiles()
            for url in sheets.bundled { byName[url.lastPathComponent] = url }
            // A sheet in the user's folder replaces a bundled one of the same name.
            for url in sheets.library { byName[url.lastPathComponent] = url }
            var assets = byName.keys.sorted().compactMap { name in Self.entry(.sprite, byName[name]!).map { ResolvedAsset(entry: $0, url: byName[name]!) } }
            // The sheet the pet shows now, under one id whatever its file is called. Same order as `Atlas.loadDefault`.
            var candidates: [URL] = []
            if let sprite, !sprite.isEmpty { candidates.append(URL(fileURLWithPath: (sprite as NSString).expandingTildeInPath)) }
            candidates += [Paths.petDir.appendingPathComponent("spritesheet.webp"), Paths.petDir.appendingPathComponent("spritesheet.png")]
            candidates += sheets.bundled.filter { $0.deletingPathExtension().lastPathComponent.lowercased() == "ghost" }
            if let url = candidates.first(where: { Self.entry(.sprite, $0) != nil }), var active = Self.entry(.sprite, url) {
                active.id = "pet.sprite"
                assets.insert(ResolvedAsset(entry: active, url: url), at: 0)
            }
            if let custom, !custom.contains("/") {
                let url = folders.backgroundsFolder.appendingPathComponent(custom)
                if var image = Self.entry(.background, url) {
                    image.id = "chat.background"
                    assets.append(ResolvedAsset(entry: image, url: url))
                }
            }
            return assets
        }.value
        resolvedCache = (key, assets)
        return assets
    }

    /// Publishes `assets.changed` when a sheet or the custom image was added, removed or rewritten since the last check.
    package func checkAssets() {
        let now = signature()
        guard now != assetSignature else { return }
        let first = assetSignature == nil
        assetSignature = now
        if !first { events?.publish(.assetsChanged) }
    }

    private func signature() -> [String] {
        assets.folderSignature()
    }

    nonisolated private static func entry(_ kind: AssetKind, _ url: URL) -> AssetEntry? {
        var size: (width: Int, height: Int)?
        if kind == .sprite {
            guard let found = Atlas.pixelSize(of: url), Atlas.isValid(width: found.width, height: found.height) else { return nil }
            size = found
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return AssetEntry(id: "\(kind.rawValue):\(url.lastPathComponent)", kind: kind, name: url.lastPathComponent, sha256: hash, bytes: data.count,
                          width: size?.width, height: size?.height)
    }
}
