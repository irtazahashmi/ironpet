import Foundation
import IronPetCore

/// Pet sheets and chat backgrounds in the app's data folder, `~/.ironpet/pets` and `~/.ironpet/backgrounds`, unless a test
/// points the folders elsewhere.
struct MacPetAssets: PetAssets {
    var libraryFolder = PetLibrary.folder
    var bundledFolder: URL? = PetLibrary.bundledFolder
    var backgroundsFolder = ChatBackground.folder

    init() {}

    init(library: URL, bundled: URL?, backgrounds: URL) {
        libraryFolder = library
        bundledFolder = bundled
        backgroundsFolder = backgrounds
    }

    var builtInNames: [String] { PetLibrary.builtInNames }

    func entries(current: String?) throws -> [PetEntry] {
        PetLibrary.entries(bundled: bundledFolder, library: libraryFolder, current: current)
    }

    func selectedID(in entries: [PetEntry], sprite: String?) -> String? { PetLibrary.selectedID(in: entries, sprite: sprite) }

    func select(_ entry: PetEntry, in config: inout Config) { PetLibrary.select(entry, in: &config) }

    func importSheet(_ source: URL) throws -> PetEntry {
        let copy = try PetLibrary.importSheet(source, into: libraryFolder)
        guard let atlas = Atlas.load(copy) else { throw PetLibrary.ImportError.notAnAtlas(source.lastPathComponent) }
        let name = PetLibrary.displayName(forStem: copy.deletingPathExtension().lastPathComponent)
        return PetEntry(id: PetLibrary.standardized(copy.path), name: name, url: copy, atlas: atlas)
    }

    func standardizedID(_ path: String) -> String { PetLibrary.standardized(path) }

    func sheetFiles() -> (bundled: [URL], library: [URL]) {
        (PetLibrary.sheetFiles(in: bundledFolder), PetLibrary.sheetFiles(in: libraryFolder))
    }

    func folderSignature() -> [String] {
        PetFolderSignature(folder: libraryFolder).items + (bundledFolder.map { PetFolderSignature(folder: $0).items } ?? [])
            + ((try? FileManager.default.contentsOfDirectory(atPath: backgroundsFolder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted().map { "bg|\($0)" }
    }

    func importBackground(from source: URL, replacing: String?) throws -> String {
        try ChatBackground.importImage(from: source, into: backgroundsFolder, replacing: replacing)
    }

    func phoneBackground(named name: String) -> URL? {
        ChatBackground.phoneCopy(of: name, in: backgroundsFolder)
    }
}
