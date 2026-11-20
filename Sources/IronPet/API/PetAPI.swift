import CryptoKit
import Foundation

struct PetState: Codable, Equatable {
    /// The mood the pet shows, such as `idle`, `working`, `needsInput`.
    var mood: String
    /// How many sessions and alerts share the mood.
    var badge: Int
}

struct PetInfo: Codable, Equatable, Identifiable {
    /// The sheet's standardized file path. Pass it back to `selectPet`.
    var id: String
    var name: String
    var builtIn: Bool
    var selected: Bool
}

struct SelectPetRequest: Codable, Equatable {
    var id: String
}

struct PerformTrickRequest: Codable, Equatable {
    /// One of the names `tricks()` lists, such as "Wave".
    var name: String
}

struct BackgroundInfo: Codable, Equatable, Identifiable {
    /// `default`, a built-in id such as `dusk`, or `custom`.
    var id: String
    var name: String
    var selected: Bool
}

struct SelectBackgroundRequest: Codable, Equatable {
    var id: String
}

enum AssetKind: String, Codable {
    case sprite, background
}

/// One file a client can download and cache. Compare `sha256` with the copy it holds to know whether it is stale.
struct AssetEntry: Codable, Equatable, Identifiable {
    /// `sprite:<file name>` or `background:<file name>` for a file of its own. `pet.sprite` and `chat.background` name the sheet and the image in use now.
    var id: String
    var kind: AssetKind
    var name: String
    var sha256: String
    var bytes: Int
    /// Pixel size, for a sprite sheet.
    var width: Int? = nil
    var height: Int? = nil
}

struct AssetManifest: Codable, Equatable {
    var assets: [AssetEntry]
}

/// The pet and how the app looks: the pet's mood and tricks, the gallery of sprite sheets, chat backgrounds, and a manifest of
/// the files behind them with content hashes, so a client can download each one once and keep it.
@MainActor
final class PetAPI {
    private let settings: SettingsAPI
    private let library: URL
    private let bundled: URL?
    private let backgrounds: URL
    private var assetSignature: [String]?
    weak var events: APIEventBus?

    /// The running app's pet API, for the Settings pages. `IronPetAPI` sets it to its own, so there is one instance.
    static var live = PetAPI(settings: .live)

    /// The pet's current mood and badge. The pet window supplies it.
    var stateProvider: () -> PetState = { PetState(mood: "idle", badge: 0) }
    /// Plays a trick by name. The pet window supplies it. Returns false for a name it does not know.
    var trickHandler: (String) -> Bool = { _ in false }
    /// The tricks the pet knows, in menu order.
    var trickNames: () -> [String] = { [] }

    init(settings: SettingsAPI, library: URL = PetLibrary.folder, bundled: URL? = PetLibrary.bundledFolder,
         backgrounds: URL = ChatBackground.folder) {
        self.settings = settings
        self.library = library
        self.bundled = bundled
        self.backgrounds = backgrounds
    }

    // MARK: Mood and tricks

    func state() -> PetState { stateProvider() }

    func tricks() -> [String] { trickNames() }

    func perform(_ request: PerformTrickRequest) throws {
        guard trickHandler(request.name) else { throw APIError.notFound("the pet does not know \"\(request.name)\"") }
    }

    // MARK: Gallery

    /// The pets in the gallery, built-in ones first. Reads the sheets off the main thread, so it can take a moment.
    func pets() async -> [PetInfo] {
        let (library, bundled, current) = (library, bundled, settings.config.pet.sprite)
        let entries = await Task.detached { PetLibrary.entries(bundled: bundled, library: library, current: current) }.value
        let selected = PetLibrary.selectedID(in: entries, sprite: current)
        return entries.map { entry in
            PetInfo(id: entry.id, name: entry.name, builtIn: PetLibrary.builtInNames.contains(entry.url.deletingPathExtension().lastPathComponent.lowercased()),
                    selected: entry.id == selected)
        }
    }

    func selectPet(_ request: SelectPetRequest) async throws {
        let (library, bundled, current) = (library, bundled, settings.config.pet.sprite)
        let entries = await Task.detached { PetLibrary.entries(bundled: bundled, library: library, current: current) }.value
        guard let entry = entries.first(where: { $0.id == request.id }) else { throw APIError.notFound("no pet with id \"\(request.id)\"") }
        select(entry)
    }

    /// Makes a gallery entry the pet.
    func select(_ entry: PetEntry) {
        let before = settings.config.pet.sprite
        settings.update { PetLibrary.select(entry, in: &$0) }
        if settings.config.pet.sprite != before { events?.publish(.assetsChanged) }
    }

    /// Copies a sprite sheet into the pet library and makes it the pet.
    @discardableResult
    func importPet(_ source: URL) throws -> PetEntry {
        let copy: URL
        do { copy = try PetLibrary.importSheet(source, into: library) } catch { throw APIError.invalid(error.localizedDescription) }
        guard let atlas = Atlas.load(copy) else { throw APIError.invalid("\(source.lastPathComponent) isn't a sprite sheet in the expected layout.") }
        let name = PetLibrary.displayName(forStem: copy.deletingPathExtension().lastPathComponent)
        let entry = PetEntry(id: PetLibrary.standardized(copy.path), name: name, url: copy, atlas: atlas)
        select(entry)
        checkAssets()
        return entry
    }

    // MARK: Backgrounds

    func backgroundList() -> [BackgroundInfo] {
        let current = settings.config.chat.background
        var list = [BackgroundInfo(id: ChatBackground.defaultID, name: "Default", selected: current == ChatBackground.defaultID)]
        list += ChatBackground.builtIns.map { BackgroundInfo(id: $0.id, name: $0.name, selected: current == $0.id) }
        list.append(BackgroundInfo(id: ChatBackground.customID, name: "Custom image", selected: current == ChatBackground.customID))
        return list
    }

    func selectBackground(_ request: SelectBackgroundRequest) throws {
        if request.id == ChatBackground.customID {
            guard settings.config.chat.customImage != nil else { throw APIError.invalid("no custom image has been added yet") }
        } else if request.id != ChatBackground.defaultID, ChatBackground.builtIn(request.id) == nil {
            throw APIError.notFound("no background with id \"\(request.id)\"")
        }
        let before = settings.config.chat.background
        settings.update { $0.chat.background = request.id }
        if request.id != before, request.id == ChatBackground.customID || before == ChatBackground.customID { events?.publish(.assetsChanged) }
    }

    /// Copies an image into the backgrounds folder and makes it the chat background. The previous custom image is removed.
    func importBackground(_ source: URL) throws {
        do {
            let name = try ChatBackground.importImage(from: source, into: backgrounds, replacing: settings.config.chat.customImage)
            settings.update { $0.chat.background = ChatBackground.customID; $0.chat.customImage = name }
            checkAssets()
        } catch {
            throw APIError.invalid(error.localizedDescription)
        }
    }

    // MARK: Assets

    /// Every file a client can download: the pet sheets, the sheet the pet shows now (`pet.sprite`) and the custom background
    /// image. A sheet that is not in the atlas layout is left out, as the gallery skips it. The built-in backgrounds are drawn
    /// from their ids, so they have no file.
    func manifest() async -> AssetManifest {
        AssetManifest(assets: await resolvedAssets().map(\.entry))
    }

    /// The bytes of an asset from `manifest`.
    func assetData(_ id: String) async throws -> Data {
        guard let asset = await resolvedAssets().first(where: { $0.entry.id == id }) else { throw APIError.notFound("no asset with id \"\(id)\"") }
        return try Self.read(asset.url)
    }

    /// The bytes of the asset with this content hash. Two ids can share one hash (`pet.sprite` and the gallery entry it is).
    func assetData(sha256: String) async throws -> (entry: AssetEntry, data: Data) {
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
        let (library, bundled, backgrounds, custom, sprite) = (library, bundled, backgrounds, settings.config.chat.customImage, settings.config.pet.sprite)
        let spriteFile = (sprite.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
            .flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) }
        let key = signature() + PetFolderSignature(folder: Paths.petDir).items
            + ["sprite|\(sprite ?? "")|\(spriteFile?.fileSize ?? 0)|\(spriteFile?.contentModificationDate?.timeIntervalSince1970 ?? 0)", "custom|\(custom ?? "")"]
        if let cached = resolvedCache, cached.key == key { return cached.assets }
        let assets = await Task.detached { () -> [ResolvedAsset] in
            var byName: [String: URL] = [:]
            for url in PetLibrary.sheetFiles(in: bundled) { byName[url.lastPathComponent] = url }
            // A sheet in the user's folder replaces a bundled one of the same name.
            for url in PetLibrary.sheetFiles(in: library) { byName[url.lastPathComponent] = url }
            var assets = byName.keys.sorted().compactMap { name in Self.entry(.sprite, byName[name]!).map { ResolvedAsset(entry: $0, url: byName[name]!) } }
            // The sheet the pet shows now, under one id whatever its file is called. Same order as `Atlas.loadDefault`.
            var candidates: [URL] = []
            if let sprite, !sprite.isEmpty { candidates.append(URL(fileURLWithPath: (sprite as NSString).expandingTildeInPath)) }
            candidates += [Paths.petDir.appendingPathComponent("spritesheet.webp"), Paths.petDir.appendingPathComponent("spritesheet.png")]
            candidates += PetLibrary.sheetFiles(in: bundled).filter { $0.deletingPathExtension().lastPathComponent.lowercased() == "ghost" }
            if let url = candidates.first(where: { Self.entry(.sprite, $0) != nil }), var active = Self.entry(.sprite, url) {
                active.id = "pet.sprite"
                assets.insert(ResolvedAsset(entry: active, url: url), at: 0)
            }
            if let custom, !custom.contains("/") {
                let url = backgrounds.appendingPathComponent(custom)
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
    func checkAssets() {
        let now = signature()
        guard now != assetSignature else { return }
        let first = assetSignature == nil
        assetSignature = now
        if !first { events?.publish(.assetsChanged) }
    }

    private func signature() -> [String] {
        PetFolderSignature(folder: library).items + (bundled.map { PetFolderSignature(folder: $0).items } ?? [])
            + ((try? FileManager.default.contentsOfDirectory(atPath: backgrounds.path)) ?? []).sorted().map { "bg|\($0)" }
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
