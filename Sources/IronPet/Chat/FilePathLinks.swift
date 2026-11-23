import AppKit
import IronPetCore
import IronPetKit
import SwiftUI

/// Turns file paths in chat text into links that open the file. Detection is pure string work. Whether a
/// path exists is answered from a cache that a background queue fills, so rendering never touches the disk:
/// a path becomes a link the first time its check finishes and the views that show it redraw.
enum FilePathLinks {
    struct Match: Equatable {
        /// Range in the scanned string, covering the path and its `:line` suffix.
        var range: Range<String.Index>
        /// Absolute path with `~` expanded and `\ ` unescaped. The `:line` suffix is removed.
        var path: String
    }

    // MARK: Detection

    /// Finds absolute paths, `~/` paths and `file://` URLs. Existence is not checked here. The rules are `ChatFilePaths`, shared with the phone.
    static func detect(in text: String) -> [Match] {
        ChatFilePaths.detect(in: text, home: NSHomeDirectory()).map { Match(range: $0.range, path: $0.path) }
    }

    // MARK: Linking

    /// Links every detected path that exists. Text that already has a link, such as a markdown link, is left alone.
    static func link(_ text: AttributedString, cache: PathCache = .shared, underline: Bool = false) -> AttributedString {
        let plain = String(text.characters)
        guard plain.contains("/") else { return text }
        var result = text
        var plainIndex = plain.startIndex
        var resultIndex = result.startIndex
        var offset = 0
        for match in detect(in: plain) {
            let lower = offset + plain.distance(from: plainIndex, to: match.range.lowerBound)
            let upper = lower + plain.distance(from: match.range.lowerBound, to: match.range.upperBound)
            let a = result.characters.index(resultIndex, offsetBy: lower - offset)
            let b = result.characters.index(a, offsetBy: upper - lower)
            plainIndex = match.range.upperBound
            resultIndex = b
            offset = upper
            guard result[a..<b].runs.allSatisfy({ $0.link == nil }) else { continue }
            let kind = cache.kind(of: match.path)
            guard kind != .missing else { continue }
            // Passing isDirectory keeps Foundation from stating the path during rendering.
            result[a..<b].link = URL(fileURLWithPath: match.path, isDirectory: kind == .directory)
            if underline { result[a..<b].underlineStyle = .single }
        }
        return result
    }

    // MARK: Opening

    enum Action: Equatable {
        case open(URL)
        case revealFolder(URL)
        /// Selects the item in Finder without launching it. Used for apps and scripts.
        case showInFinder(URL)
        case ignore
    }

    /// Opening these would run code, so a click only selects them in Finder.
    private static let launchesCode: Set<String> = [
        "app", "command", "terminal", "tool", "sh", "zsh", "bash", "pkg", "mpkg", "workflow", "scpt",
        "scptd", "action", "jar", "webloc", "url", "dmg", "service", "prefpane", "saver", "xpc",
    ]

    /// Folders open in Finder and files in their default app, both through `NSWorkspace.open`. Missing paths do nothing.
    static func action(for url: URL, cache: PathCache = .shared) -> Action {
        guard url.isFileURL else { return .ignore }
        let resolved = url.resolvingSymlinksInPath()
        let runs = launchesCode.contains(url.pathExtension.lowercased())
            || launchesCode.contains(resolved.pathExtension.lowercased())
            || FileManager.default.isExecutableFile(atPath: resolved.path)
                && !resolved.hasDirectoryPath && cache.kindNow(of: resolved.path) == .file
        if runs, cache.kindNow(of: url.path) != .missing { return .showInFinder(url) }
        switch cache.kindNow(of: url.path) {
        case .directory: return .revealFolder(url)
        case .file: return .open(url)
        case .missing: return .ignore
        }
    }

    /// Replaced by tests to observe what a click would open.
    nonisolated(unsafe) static var opener: (URL) -> Void = { url in
        NSLog("ironpet: opening file link %@", url.path)
        NSWorkspace.shared.open(url)
    }

    static func handle(_ url: URL) -> OpenURLAction.Result {
        guard url.isFileURL else { return .systemAction }
        switch action(for: url) {
        case .open(let url), .revealFolder(let url): opener(url)
        case .showInFinder(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .ignore: break
        }
        return .handled
    }
}

enum PathKind: Equatable { case file, directory, missing }

/// Remembers whether paths exist. `kind(of:)` never touches the disk: it answers from memory, schedules a
/// background check for unknown or stale paths, and reports unknown paths as missing. When a check finds
/// something that exists, `version` changes so observing views redraw.
final class PathCache: ObservableObject, @unchecked Sendable {
    static let shared = PathCache()

    @Published private(set) var version = 0

    private struct Entry { var kind: PathKind; var checked: Date }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var pending: Set<String> = []
    private var bumpQueued = false
    private let queue = DispatchQueue(label: "ironpet.path-cache", qos: .utility)
    private let missingTTL: TimeInterval = 30
    private let foundTTL: TimeInterval = 300
    private let limit = 5000

    func kind(of path: String) -> PathKind {
        lock.lock()
        let entry = entries[path]
        let stale = entry.map { Date().timeIntervalSince($0.checked) > ($0.kind == .missing ? missingTTL : foundTTL) } ?? true
        let schedule = stale && !pending.contains(path)
        if schedule { pending.insert(path) }
        lock.unlock()
        if schedule { queue.async { [weak self] in self?.refresh(path) } }
        return entry?.kind ?? .missing
    }

    /// Blocks on the disk when the path is not cached. Only for click handling, never for rendering.
    func kindNow(of path: String) -> PathKind {
        lock.lock()
        let cached = entries[path]
        lock.unlock()
        if let cached, cached.kind != .missing { return cached.kind }
        let kind = Self.stat(path)
        store(path, kind)
        return kind
    }

    private func refresh(_ path: String) {
        let kind = Self.stat(path)
        lock.lock()
        let before = entries[path]?.kind
        pending.remove(path)
        lock.unlock()
        store(path, kind)
        guard kind != before, kind != .missing || before != nil else { return }
        lock.lock()
        let alreadyQueued = bumpQueued
        bumpQueued = true
        lock.unlock()
        guard !alreadyQueued else { return }
        // Waiting briefly merges the bumps from one message's paths into a single redraw.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.bumpQueued = false
            self.lock.unlock()
            self.version += 1
        }
    }

    private func store(_ path: String, _ kind: PathKind) {
        lock.lock()
        if entries.count >= limit { entries.removeAll() }
        entries[path] = Entry(kind: kind, checked: Date())
        lock.unlock()
    }

    /// Seeds an answer without touching the disk. Tests only.
    func prime(_ path: String, _ kind: PathKind) { store(path, kind) }

    private static func stat(_ path: String) -> PathKind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        return isDirectory.boolValue ? .directory : .file
    }
}
