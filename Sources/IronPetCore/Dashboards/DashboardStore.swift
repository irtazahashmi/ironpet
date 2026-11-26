import Foundation
#if canImport(Combine)
import Combine
#endif

/// Where dashboards live. `~/.ironpet/dashboards/<id>/` holds `manifest.json`, `main.js` and `storage.json`. The user's decisions about
/// capabilities are in `approvals.json` beside the folders, so a script that rewrites its own folder cannot approve itself.
package struct DashboardPaths {
    package init(root: URL) { self.root = root }

    package var root: URL

    package static let standard = DashboardPaths(root: Paths.root.appendingPathComponent("dashboards"))

    package func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    package func manifest(_ id: String) -> URL { folder(id).appendingPathComponent("manifest.json") }
    package func script(_ id: String) -> URL { folder(id).appendingPathComponent("main.js") }
    package func storage(_ id: String) -> URL { folder(id).appendingPathComponent("storage.json") }
    package var approvals: URL { root.appendingPathComponent("approvals.json") }
}

/// The dashboards on disk, kept in step with their files. A hand edit or an agent's write to a manifest or a script is picked up
/// within two seconds, which is how "editing a dashboard's code reloads it" works. A folder that does not validate is left out and
/// the last good copy of it stays active.
///
/// Each dashboard has its own storage, a JSON object in its folder. Nothing else of IronPet's is stored there.
@MainActor
package final class DashboardStore {
    /// Fires before `dashboards` or a dashboard's storage changes.
    package let changes = ChangeSignal()
    package private(set) var dashboards: [Dashboard] = [] {
        willSet { changes.send() }
    }
    /// Where `dashboards.changed` is published for API clients, with the id of the dashboard.
    package weak var events: APIEventBus?
    package let paths: DashboardPaths
    /// Problems found while reading folders, by dashboard id. Shown beside the dashboard.
    package private(set) var problems: [String: String] = [:]

    package static let maxStorageBytes = 256 * 1024

    private var approvals: [String: DashboardApproval] = [:]
    private var stamps: [String: [Date?]] = [:]
    private var timer: Timer?

    package init(paths: DashboardPaths = .standard, watch: Bool = true) {
        self.paths = paths
        approvals = Self.readApprovals(paths.approvals)
        reload(force: true)
        if watch {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    // MARK: Reading

    package func dashboard(_ id: String) -> Dashboard? { dashboards.first { $0.id == id } }

    /// Reads every dashboard folder whose files changed since the last look.
    package func reload(force: Bool = false) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: paths.root.path)) ?? [])
            .filter { DashboardValidator.isID($0) && Self.isDirectory(paths.folder($0)) }.sorted()
        var list = dashboards
        var changed: [String] = []
        for gone in dashboards.map(\.id) where !names.contains(gone) {
            list.removeAll { $0.id == gone }
            stamps[gone] = nil
            problems[gone] = nil
            changed.append(gone)
        }
        for id in names {
            let stamp = [paths.manifest(id), paths.script(id), paths.storage(id)].map(Self.modificationDate)
            guard force || stamps[id] != stamp else { continue }
            let storageOnly = stamps[id].map { $0[0] == stamp[0] && $0[1] == stamp[1] } ?? false
            stamps[id] = stamp
            if storageOnly, list.contains(where: { $0.id == id }) {
                changed.append(id)
                continue
            }
            switch Self.read(paths, id) {
            case .success(let dashboard):
                problems[id] = nil
                if let index = list.firstIndex(where: { $0.id == id }) {
                    if list[index] != dashboard { list[index] = dashboard }
                } else {
                    list.append(dashboard)
                }
            case .failure(let message):
                problems[id] = message
            }
            changed.append(id)
        }
        list.sort { $0.id < $1.id }
        if list != dashboards { dashboards = list } else if !changed.isEmpty { changes.send() }
        for id in changed { events?.publish(.dashboardsChanged, id: id) }
    }

    private enum ReadResult {
        case success(Dashboard)
        case failure(String)
    }

    private static func read(_ paths: DashboardPaths, _ id: String) -> ReadResult {
        guard let manifestData = try? Data(contentsOf: paths.manifest(id)) else { return .failure("manifest.json is missing") }
        let manifest: DashboardManifest
        do { manifest = try JSONDecoder().decode(DashboardManifest.self, from: manifestData) } catch {
            return .failure("manifest.json: \(describe(error))")
        }
        let script = (try? String(contentsOf: paths.script(id), encoding: .utf8)) ?? ""
        if let problem = DashboardValidator.problem(manifest: manifest, script: script) { return .failure(problem) }
        return .success(Dashboard(id: id, manifest: manifest, script: script))
    }

    private static func describe(_ error: Error) -> String {
        if case DecodingError.keyNotFound(let key, _) = error { return "\"\(key.stringValue)\" is missing" }
        if case DecodingError.dataCorrupted = error { return "it is not valid JSON" }
        return "it does not match the format"
    }

    // MARK: Writing

    /// Writes a new dashboard. `id` must be free. Nothing is approved: a dashboard that declares capabilities waits for the user.
    @discardableResult
    package func create(id: String, manifest: DashboardManifest, script: String) throws -> Dashboard {
        guard DashboardValidator.isID(id) else { throw APIError.invalid("id must be lowercase letters, digits and dashes, up to 40 characters") }
        guard dashboard(id) == nil, !FileManager.default.fileExists(atPath: paths.folder(id).path) else { throw APIError.conflict("a dashboard with id \(id) exists") }
        if let problem = DashboardValidator.problem(manifest: manifest, script: script) { throw APIError.invalid(problem) }
        try write(id: id, manifest: manifest, script: script)
        reload()
        guard let created = dashboard(id) else { throw APIError.failed("the dashboard could not be read back") }
        return created
    }

    /// Replaces the manifest, the script or both. A new capability in the manifest waits for the user.
    package func update(_ id: String, manifest: DashboardManifest? = nil, script: String? = nil) throws {
        guard let current = dashboard(id) else { throw APIError.notFound("no dashboard \(id)") }
        let newManifest = manifest ?? current.manifest, newScript = script ?? current.script
        if let problem = DashboardValidator.problem(manifest: newManifest, script: newScript) { throw APIError.invalid(problem) }
        try write(id: id, manifest: newManifest, script: newScript)
        reload()
    }

    /// Removes the folder, with its storage, and the user's decisions about it.
    package func delete(_ id: String) throws {
        guard dashboard(id) != nil || FileManager.default.fileExists(atPath: paths.folder(id).path) else { throw APIError.notFound("no dashboard \(id)") }
        guard DashboardValidator.isID(id) else { throw APIError.invalid("bad id") }
        try FileManager.default.removeItem(at: paths.folder(id))
        approvals[id] = nil
        try? writeApprovals()
        reload()
    }

    private func write(id: String, manifest: DashboardManifest, script: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: paths.folder(id), withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: paths.manifest(id), options: .atomic)
        try Data(script.utf8).write(to: paths.script(id), options: .atomic)
    }

    // MARK: Storage

    /// The dashboard's saved state. Empty when it has none or the file is damaged.
    package func data(_ id: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: paths.storage(id)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object
    }

    /// Replaces the saved state.
    package func setData(_ id: String, _ value: [String: Any]) throws {
        guard dashboard(id) != nil else { throw APIError.notFound("no dashboard \(id)") }
        guard JSONSerialization.isValidJSONObject(value) else { throw APIError.invalid("the data is not JSON") }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= Self.maxStorageBytes else { throw APIError.invalid("the data is larger than \(Self.maxStorageBytes / 1024) KiB") }
        guard data != (try? Data(contentsOf: paths.storage(id))) else { return }
        try data.write(to: paths.storage(id), options: .atomic)
        reload()
    }

    /// Sets the keys in `patch` on the saved state. A key whose value is null is removed. Returns the new state.
    @discardableResult
    package func merge(_ id: String, _ patch: [String: Any]) throws -> [String: Any] {
        var state = data(id)
        for (key, value) in patch {
            if value is NSNull { state[key] = nil } else { state[key] = value }
        }
        try setData(id, state)
        return state
    }

    // MARK: Approval

    /// What the dashboard declares that the user has not decided on yet.
    package func undecided(_ id: String) -> Set<String> {
        guard let dashboard = dashboard(id) else { return [] }
        let decision = approvals[id] ?? DashboardApproval()
        return dashboard.manifest.capabilities.tokens.subtracting(decision.approved).subtracting(decision.denied)
    }

    /// Whether the user was ever asked about this dashboard. False for a new one, which is what makes the sheet read "Add dashboard".
    package func wasDecided(_ id: String) -> Bool { approvals[id] != nil }

    /// What a script may do: declared and approved. A capability a script gains by an edit is not in it until the user approves it.
    package func allowed(_ id: String) -> Set<String> {
        guard let dashboard = dashboard(id) else { return [] }
        return dashboard.manifest.capabilities.tokens.intersection(approvals[id]?.approved ?? [])
    }

    /// Approves everything the dashboard declares now.
    package func approve(_ id: String) throws {
        guard let dashboard = dashboard(id) else { throw APIError.notFound("no dashboard \(id)") }
        var decision = approvals[id] ?? DashboardApproval()
        decision.approved.formUnion(dashboard.manifest.capabilities.tokens)
        decision.denied.subtract(decision.approved)
        approvals[id] = decision
        try writeApprovals()
        changes.send()
        events?.publish(.dashboardsChanged, id: id)
    }

    /// Refuses what is undecided. The script keeps what was approved before, and the refused capabilities stay off.
    package func deny(_ id: String) throws {
        guard dashboard(id) != nil else { throw APIError.notFound("no dashboard \(id)") }
        var decision = approvals[id] ?? DashboardApproval()
        decision.denied.formUnion(undecided(id))
        approvals[id] = decision
        try writeApprovals()
        changes.send()
        events?.publish(.dashboardsChanged, id: id)
    }

    private func writeApprovals() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try encoder.encode(approvals).write(to: paths.approvals, options: .atomic)
    }

    private static func readApprovals(_ url: URL) -> [String: DashboardApproval] {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([String: DashboardApproval].self, from: data) else { return [:] }
        return list
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

#if canImport(Combine)
extension DashboardStore: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
