import Foundation

/// The sprite sheets and chat background images on disk: the bundled pets, the user's pet folder, and the folder of imported
/// backgrounds. `PetAPI` lists, selects and imports through this protocol and never touches a folder itself. The Mac adapter
/// is `MacPetAssets`, over `PetLibrary` and `ChatBackground`.
package protocol PetAssets: Sendable {
    /// False for the `Unsupported` adapter, which `Platform.capabilities` reports.
    var isSupported: Bool { get }
    /// The user's pet folder, where imported sheets go.
    var libraryFolder: URL { get }
    /// The sheets that ship inside the app, when there are any.
    var bundledFolder: URL? { get }
    /// Where imported background images go.
    var backgroundsFolder: URL { get }
    /// The pets that come with the app, in gallery order.
    var builtInNames: [String] { get }

    /// Every pet to show: the bundled ones, then the user's, then `current` when it lives elsewhere. Reads the sheets, so call it
    /// off the main thread.
    func entries(current: String?) throws -> [PetEntry]
    /// The entry `sprite` points at. Unset means the bundled Ghost.
    func selectedID(in entries: [PetEntry], sprite: String?) -> String?
    /// Makes `entry` the pet in `config`.
    func select(_ entry: PetEntry, in config: inout Config)
    /// Copies a sprite sheet into the pet folder and returns the copy as an entry. Throws when it is not a sheet.
    func importSheet(_ source: URL) throws -> PetEntry
    /// The id (a standardized file path) a sheet at `path` has in the gallery.
    func standardizedID(_ path: String) -> String
    /// The sheet files in the bundled and user folders, by folder.
    func sheetFiles() -> (bundled: [URL], library: [URL])
    /// Names, sizes and dates of every sheet and background file, so a caller can tell when one changed.
    func folderSignature() -> [String]
    /// Copies an image into the backgrounds folder under a fresh name, removes `replacing`, and returns the new file name.
    func importBackground(from source: URL, replacing: String?) throws -> String
}

extension PetAssets {
    package var isSupported: Bool { true }
}

/// Has no pets and no backgrounds.
package struct UnsupportedPetAssets: PetAssets {
    package init() {}

    package var platform = PlatformName.current
    package var isSupported: Bool { false }
    package var libraryFolder: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ironpet-unsupported-pets") }
    package var bundledFolder: URL? { nil }
    package var backgroundsFolder: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ironpet-unsupported-backgrounds") }
    package var builtInNames: [String] { [] }
    private var error: CapabilityError { .unsupported(capability: "PetAssets", platform: platform) }

    package func entries(current: String?) throws -> [PetEntry] { throw error }
    package func selectedID(in entries: [PetEntry], sprite: String?) -> String? { nil }
    package func select(_ entry: PetEntry, in config: inout Config) {}
    package func importSheet(_ source: URL) throws -> PetEntry { throw error }
    package func standardizedID(_ path: String) -> String { path }
    package func sheetFiles() -> (bundled: [URL], library: [URL]) { ([], []) }
    package func folderSignature() -> [String] { [] }
    package func importBackground(from source: URL, replacing: String?) throws -> String { throw error }
}
