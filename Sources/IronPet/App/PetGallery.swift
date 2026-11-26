import AppKit
import enum IronPetKit.SharedTheme
import IronPetCore
import SwiftUI
import UniformTypeIdentifiers

/// The animation time lives apart from the model so only the tiles redraw on each tick, not the whole gallery.
@MainActor
final class PetClock: ObservableObject {
    @Published var time: Double = 0
}

/// Backs the pet gallery in Settings. One timer drives every tile's animation and another polls the pets folder, and
/// both run only while a pet's details are on screen. The gallery edits one pet at a time: the first pet's image lives in
/// `config.pet.sprite`, every other pet's in its record.
@MainActor
final class PetGalleryModel: ObservableObject {
    @Published private(set) var entries: [PetEntry] = []
    /// Seconds of animation, advanced by the single animation timer.
    let clock = PetClock()
    @Published var importError: String?

    /// Tests set this to exercise the Reduce Motion path.
    var reduceMotionOverride: Bool?
    var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private let library: URL
    private let bundled: URL?
    /// The pet API the gallery selects and imports through. `AppDelegate` sets the app's; the default works on `library`.
    lazy var api = PetAPI(settings: .live, assets: MacPetAssets(library: library, bundled: bundled, backgrounds: ChatBackground.folder))
    private let spriteOverride: (() -> String?)?
    /// The sprite of the pet whose details are open, for the "current" tile when its sheet lives outside the pets folder.
    var currentSprite: (() -> String?)?
    /// A pet waiting for a built sheet: the sheets known when the build started, so the first new one goes to that pet.
    private var pendingBuild: (petID: String, records: AgentRecordsAPI?, known: Set<String>)?
    private lazy var assets = MacPetAssets(library: library, bundled: bundled, backgrounds: ChatBackground.folder)
    private var animationTimer: Timer?
    private var pollTimer: Timer?
    private var signature: PetFolderSignature?
    private var generation = 0
    private(set) var viewShown = false
    private(set) var windowShown = false

    init(library: URL = PetLibrary.folder, bundled: URL? = PetLibrary.bundledFolder,
         sprite: (() -> String?)? = nil) {
        self.library = library
        self.bundled = bundled
        self.spriteOverride = sprite
    }

    private var sprite: String? { spriteOverride.map { $0() } ?? currentSprite?() ?? SettingsAPI.live.config.pet.sprite }

    var isActive: Bool { viewShown && windowShown }

    func setViewShown(_ shown: Bool) {
        viewShown = shown
        refreshActivity()
    }

    func setWindowShown(_ shown: Bool) {
        windowShown = shown
        refreshActivity()
    }

    private func refreshActivity() {
        if isActive { start() } else { stop() }
    }

    private func start() {
        guard pollTimer == nil else { return }
        reload()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        }
        if !reduceMotion {
            animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.clock.time += 1.0 / 15 }
            }
        }
    }

    private func stop() {
        pollTimer?.invalidate()
        animationTimer?.invalidate()
        pollTimer = nil
        animationTimer = nil
        // Drop the decoded sheets (about 16 MB each) while Settings is closed.
        generation += 1
        entries = []
        signature = nil
    }

    /// Reloads the gallery when a sheet in the pets folder was added, removed or rewritten.
    func reloadIfChanged() {
        let now = PetFolderSignature(folder: library)
        guard now != signature else { return }
        reload()
    }

    /// Decodes the sheets off the main thread, then replaces the tiles.
    func reload() {
        signature = PetFolderSignature(folder: library)
        generation += 1
        let (id, library, bundled, current) = (generation, library, bundled, sprite)
        Task.detached { [weak self] in
            let entries = PetLibrary.entries(bundled: bundled, library: library, current: current)
            await MainActor.run { [weak self] in
                guard let self, self.generation == id else { return }
                self.entries = entries
                self.assignBuilt(from: entries)
            }
        }
    }

    private static func isFirst(_ petID: String) -> Bool { petID == AgentRegistry.chatAgentID }

    /// Makes `entry` the image of the pet `petID`.
    func select(_ entry: PetEntry, petID: String, records: AgentRecordsAPI?) {
        if Self.isFirst(petID) {
            api.select(entry)
        } else {
            setSprite(PetLibrary.tildePath(entry.url), petID: petID, records: records)
        }
    }

    /// Puts the pet back on the bundled Ghost.
    func reset(petID: String, records: AgentRecordsAPI?) {
        if Self.isFirst(petID) {
            SettingsAPI.live.update { $0.pet.sprite = nil }
        } else {
            setSprite("", petID: petID, records: records)
        }
    }

    private func setSprite(_ path: String, petID: String, records: AgentRecordsAPI?) {
        do {
            try records?.update(UpdateAgentRequest(id: petID, pet: path))
            importError = nil
        } catch {
            importError = (error as? APIError)?.message ?? error.localizedDescription
        }
    }

    /// Copies a sheet the user picked into the pets folder and makes it the image of the pet `petID`.
    func add(_ url: URL, petID: String, records: AgentRecordsAPI?) {
        do {
            if Self.isFirst(petID) {
                try api.importPet(url)
            } else {
                let entry: PetEntry
                do { entry = try assets.importSheet(url) } catch { throw APIError.invalid(error.localizedDescription) }
                setSprite(PetLibrary.tildePath(entry.url), petID: petID, records: records)
            }
            importError = nil
            reload()
        } catch {
            importError = (error as? APIError)?.message ?? error.localizedDescription
        }
    }

    /// "Build a new pet" was sent for this pet. The first sheet that shows up in the pets folder afterwards becomes its image.
    func buildStarted(petID: String, records: AgentRecordsAPI?) {
        pendingBuild = (petID, records, Set(entries.map(\.id)))
    }

    private func assignBuilt(from entries: [PetEntry]) {
        guard let pending = pendingBuild, let entry = entries.first(where: { !pending.known.contains($0.id) }) else { return }
        pendingBuild = nil
        select(entry, petID: pending.petID, records: pending.records)
    }
}

/// The image picker of one pet's details: the sprite grid, "Build a new pet", "Add from file…" and "Reset".
struct PetGallery: View {
    @ObservedObject var gallery: PetGalleryModel
    let petID: String
    @ObservedObject var records: AgentRecordsAPI
    var buildPet: (String) -> Void
    @ObservedObject private var store = SettingsAPI.live
    @State private var asking = false

    /// The sheet this pet shows. Nil is the bundled Ghost.
    private var sprite: String? {
        petID == AgentRegistry.chatAgentID ? store.config.pet.sprite : (try? records.get(petID))?.pet
    }

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 10)]

    var body: some View {
        let selected = PetLibrary.selectedID(in: gallery.entries, sprite: sprite)
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(gallery.entries.enumerated()), id: \.element.id) { index, entry in
                    PetTile(entry: entry, index: index, isSelected: entry.id == selected, gallery: gallery, clock: gallery.clock) {
                        gallery.select(entry, petID: petID, records: records)
                    }
                }
                BuildTile { asking = true }
            }
            HStack {
                Button("Add from file…", action: addFromFile).controlSize(.small)
                if sprite != nil {
                    Button("Reset") { gallery.reset(petID: petID, records: records) }.controlSize(.small)
                }
            }
            if let error = gallery.importError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                Text("Pets in ~/.ironpet/pets appear here. A sheet is a PNG or WebP in the Codex pet v2 layout: 1536 px wide, 8 columns of 192×208 cells.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            gallery.currentSprite = { [petID, records] in
                petID == AgentRegistry.chatAgentID ? SettingsAPI.live.config.pet.sprite : (try? records.get(petID))?.pet
            }
            gallery.setViewShown(true)
        }
        .onDisappear { gallery.setViewShown(false) }
        .sheet(isPresented: $asking) {
            BuildPetSheet { description in
                asking = false
                if let description {
                    gallery.buildStarted(petID: petID, records: records)
                    buildPet(description)
                }
            }
        }
    }

    private func addFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .webP]
        panel.directoryURL = PetLibrary.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        gallery.add(url, petID: petID, records: records)
    }
}

private struct PetTile: View {
    let entry: PetEntry
    let index: Int
    let isSelected: Bool
    let gallery: PetGalleryModel
    @ObservedObject var clock: PetClock
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 4) {
                preview.frame(width: 64, height: 69)
                Text(entry.name).font(.caption).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.15) : SharedTheme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("Use \(entry.name) as this pet's image")
    }

    @ViewBuilder private var preview: some View {
        // Each tile starts at a different point so the grid doesn't move in lockstep.
        let offset = Double(index) * 0.7
        if let frame = PetPreview.frame(in: entry.atlas, at: clock.time + offset, reduceMotion: gallery.reduceMotion) {
            Image(decorative: frame, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        }
    }
}

private struct BuildTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: "plus.circle").font(.system(size: 28)).foregroundStyle(.secondary).frame(width: 64, height: 69)
                Text("Build a new pet").font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4])))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Ask the chat to draw a new image for this pet")
    }
}

private struct BuildPetSheet: View {
    var done: (String?) -> Void
    @State private var description = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Describe your pet").font(.headline)
            TextEditor(text: $description)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 96)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("a red fox with a scarf").foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Send to chat", action: submit).keyboardShortcut(.return, modifiers: .command).disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var trimmed: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        done(trimmed)
    }
}
