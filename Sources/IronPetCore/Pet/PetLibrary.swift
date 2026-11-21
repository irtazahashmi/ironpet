import Foundation

/// One pet in the settings gallery: a valid sprite sheet and the name shown on its tile.
package struct PetEntry: Identifiable, @unchecked Sendable {
    package init(id: String, name: String, url: URL, atlas: Atlas) {
        self.id = id
        self.name = name
        self.url = url
        self.atlas = atlas
    }

    /// The sheet's standardized file path.
    package let id: String
    package let name: String
    package let url: URL
    package let atlas: Atlas
}

/// Where pets come from: the sheets bundled in the app, and the user's own folder `~/.ironpet/pets`.
package enum PetLibrary {
    /// The user's pet library. New sheets dropped here join the gallery.
    package static var folder: URL { Paths.root.appendingPathComponent("pets") }
    /// The six sheets `scripts/bundle.sh` generates into the app's Resources.
    package static var bundledFolder: URL? { Bundle.main.resourceURL?.appendingPathComponent("pets") }
    /// The order of `tools/make_pet.swift`'s lineup.
    package static let builtInNames = ["ghost", "mochi", "hamster", "panda", "bunny", "cat"]
    package static let sheetExtensions: Set<String> = ["png", "webp"]

    /// "red-fox" becomes "Red fox".
    package static func displayName(forStem stem: String) -> String {
        let words = stem.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    package static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
    }

    package static func tildePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: Paths.home.path, with: "~", options: .anchored)
    }

    /// Sheet files in a folder, skipping hidden files and anything that is not a PNG or WebP.
    package static func sheetFiles(in folder: URL?) -> [URL] {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { sheetExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Every pet to show: the bundled six, then the user's folder, then the current `pet.sprite` when it lives elsewhere.
    /// A sheet in the user's folder replaces a bundled pet of the same name. Files that are not valid atlases are skipped.
    package static func entries(bundled: URL?, library: URL, current: String?) -> [PetEntry] {
        var byStem: [String: PetEntry] = [:]
        func add(_ url: URL) {
            let stem = url.deletingPathExtension().lastPathComponent
            guard !stem.isEmpty, let atlas = Atlas.load(url) else { return }
            byStem[stem.lowercased()] = PetEntry(id: standardized(url.path), name: displayName(forStem: stem), url: url, atlas: atlas)
        }
        sheetFiles(in: bundled).forEach(add)
        sheetFiles(in: library).forEach(add)
        let builtIn = builtInNames.compactMap { byStem.removeValue(forKey: $0) }
        var result = builtIn + byStem.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let current, !current.isEmpty, !result.contains(where: { $0.id == standardized(current) }) {
            let url = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
            if let atlas = Atlas.load(url) {
                result.append(PetEntry(id: standardized(current), name: displayName(forStem: url.deletingPathExtension().lastPathComponent),
                                       url: url, atlas: atlas))
            }
        }
        return result
    }

    /// The entry `pet.sprite` points at. Unset means the bundled Ghost.
    package static func selectedID(in entries: [PetEntry], sprite: String?) -> String? {
        if let sprite, !sprite.isEmpty { return entries.first { $0.id == standardized(sprite) }?.id }
        return entries.first { $0.url.deletingPathExtension().lastPathComponent.lowercased() == "ghost" }?.id
    }

    /// Makes `entry` the pet. The name follows only while it is still a default name: one of the built-in pets, or the
    /// name of the pet being replaced. A name the user typed stays.
    package static func select(_ entry: PetEntry, in config: inout Config) {
        let previous: String
        if let sprite = config.pet.sprite, !sprite.isEmpty {
            previous = displayName(forStem: ((sprite as NSString).lastPathComponent as NSString).deletingPathExtension)
        } else {
            previous = "Ghost"
        }
        let defaults = (builtInNames.map(displayName(forStem:)) + [previous]).map { $0.lowercased() }
        if defaults.contains(config.pet.name.lowercased()) { config.pet.name = entry.name }
        config.pet.sprite = tildePath(entry.url)
    }

    package enum ImportError: LocalizedError {
        case notAnAtlas(String)
        package var errorDescription: String? {
            switch self {
            case .notAnAtlas(let name): "\(name) isn't a sprite sheet in the expected layout."
            }
        }
    }

    /// Copies a sheet into the library folder under an unused name and returns the copy.
    package static func importSheet(_ source: URL, into folder: URL) throws -> URL {
        guard Atlas.load(source) != nil else { throw ImportError.notAnAtlas(source.lastPathComponent) }
        if source.deletingLastPathComponent().resolvingSymlinksInPath() == folder.resolvingSymlinksInPath() { return source }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.lowercased()
        var target = folder.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(stem)-\(n).\(ext)")
            n += 1
        }
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }
}

/// Detects changes to the pet folder by comparing file names, sizes and dates. The gallery polls it every couple of
/// seconds while Settings is open, which also catches a sheet an agent rewrites in place.
package struct PetFolderSignature: Equatable {
    package let items: [String]

    package init(folder: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        items = PetLibrary.sheetFiles(in: folder).map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return "\(url.lastPathComponent)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
    }
}
