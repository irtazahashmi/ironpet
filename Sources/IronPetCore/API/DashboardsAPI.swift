import Foundation
import IronPetKit
#if canImport(Combine)
import Combine
#endif

package struct DashboardIDRequest: Codable, Equatable {
    package init(id: String) { self.id = id }
    package var id: String
}

package struct CreateDashboardRequest: Codable, Equatable {
    package init(id: String? = nil, title: String, icon: String? = nil, color: String? = nil, count: Bool? = nil,
                 capabilities: DashboardCapabilities? = nil, script: String, by: String = "user") {
        self.id = id
        self.title = title
        self.icon = icon
        self.color = color
        self.count = count
        self.capabilities = capabilities
        self.script = script
        self.by = by
    }

    /// Made from the title when missing.
    package var id: String?
    package var title: String
    package var icon: String?
    package var color: String?
    package var count: Bool?
    package var capabilities: DashboardCapabilities?
    package var script: String
    package var by = "user"
}

/// A nil field keeps its value.
package struct UpdateDashboardRequest: Codable, Equatable {
    package init(id: String, title: String? = nil, icon: String? = nil, color: String? = nil, count: Bool? = nil,
                 capabilities: DashboardCapabilities? = nil, script: String? = nil, by: String = "user") {
        self.id = id
        self.title = title
        self.icon = icon
        self.color = color
        self.count = count
        self.capabilities = capabilities
        self.script = script
        self.by = by
    }

    package var id: String
    package var title: String?
    package var icon: String?
    package var color: String?
    package var count: Bool?
    package var capabilities: DashboardCapabilities?
    package var script: String?
    package var by = "user"
}

package struct DashboardClickRequest: Codable, Equatable {
    package init(id: String, handler: String) {
        self.id = id
        self.handler = handler
    }

    package var id: String
    package var handler: String
}

/// A nil field keeps its value. The icon is an SF Symbol name and the colour one of `DashboardColors.names`.
package struct DashboardAppearanceRequest: Codable, Equatable {
    package init(id: String, icon: String? = nil, color: String? = nil) {
        self.id = id
        self.icon = icon
        self.color = color
    }

    package var id: String
    package var icon: String?
    package var color: String?
}

/// Merges `data` (a JSON object) into a dashboard's storage. A null value removes the key.
package struct DashboardPostRequest: Codable, Equatable {
    package init(id: String, data: String, by: String = "user") {
        self.id = id
        self.data = data
        self.by = by
    }

    package var id: String
    package var data: String
    package var by = "user"
}

/// A dashboard in full, for the editor and for the pet.
package struct DashboardDetail: Codable, Equatable {
    package var dashboard: RemoteDashboard
    package var manifest: DashboardManifest
    package var script: String
    /// The saved state, as JSON text.
    package var data: String
    /// Why the folder on disk is not valid, when it is not.
    package var problem: String?
    /// The capabilities the user has not decided on yet.
    package var undecided: [String]
    /// False until the user was asked once. The sheet reads "Add dashboard" for a new one.
    package var decided: Bool
}

package struct DashboardData: Codable, Equatable {
    package var id: String
    package var title: String
    package var data: String
}

/// The dashboards: small apps the user asks the pet for. A dashboard is a manifest and a script (`DashboardRuntime`) with its own
/// storage. The Mac runs the script and every client gets the finished view, so the phone draws the same dashboards.
///
/// This API is the only path to a dashboard's folder. The pet's tools, the remote API, an automation's `dashboard` action and the
/// window all go through it, and the capability check in `DashboardRuntime` applies to all of them.
@MainActor
package final class DashboardsAPI {
    /// What a script may read and change of IronPet's own data, and how a click reaches the chat.
    package struct Sources {
        package init(inbox: @escaping () -> [[String: Any]] = { [] }, alerts: @escaping () -> [[String: Any]] = { [] },
                     agents: @escaping () -> [[String: Any]] = { [] }, inboxDone: @escaping (String) throws -> Void = { _ in },
                     inboxRemove: @escaping (String) throws -> Void = { _ in },
                     prompt: @escaping (_ text: String, _ dashboard: String) async throws -> Void = { _, _ in },
                     spawner: ProcessSpawner = UnsupportedProcessSpawner()) {
            self.inbox = inbox
            self.alerts = alerts
            self.agents = agents
            self.inboxDone = inboxDone
            self.inboxRemove = inboxRemove
            self.prompt = prompt
            self.spawner = spawner
        }

        package var inbox: () -> [[String: Any]]
        package var alerts: () -> [[String: Any]]
        package var agents: () -> [[String: Any]]
        package var inboxDone: (String) throws -> Void
        package var inboxRemove: (String) throws -> Void
        /// Sends the pet a prompt the way a message typed in the chat is sent, marked as from this dashboard.
        package var prompt: (_ text: String, _ dashboard: String) async throws -> Void
        package var spawner: ProcessSpawner
    }

    /// A dashboards API with nothing in it, for a view that has no real one: a preview or a test.
    package static let unavailable = DashboardsAPI(store: DashboardStore(
        paths: DashboardPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-no-dashboards")), watch: false))

    /// Fires before anything this API reads changes.
    package let changes = ChangeSignal()
    package let store: DashboardStore
    package var sources: Sources
    /// The host a script gets. Tests replace it.
    package var host: DashboardRuntime.Host?

    private var forwarding: [ChangeToken] = []
    private var counts: [String: Int] = [:] {
        willSet { changes.send() }
    }
    private var countTask: Task<Void, Never>?

    package init(store: DashboardStore, sources: Sources = Sources()) {
        self.store = store
        self.sources = sources
        forwarding = [store.changes.observe { [weak self] in
            self?.changes.send()
            self?.scheduleCounts()
        }]
        scheduleCounts()
    }

    private func runtimeHost() -> DashboardRuntime.Host {
        if let host { return host }
        let sources = sources
        return .system(spawner: sources.spawner, read: { name in
            switch name {
            case "inbox": return sources.inbox()
            case "alerts": return sources.alerts()
            case "agents": return sources.agents()
            default: return []
            }
        }, write: { op, id in
            do {
                if op == "inboxDone" { try sources.inboxDone(id) } else { try sources.inboxRemove(id) }
                return nil
            } catch { return error.localizedDescription }
        })
    }

    // MARK: Reading

    package func list() -> [RemoteDashboard] { store.dashboards.map(summary) }

    package func get(_ id: String) throws -> DashboardDetail {
        guard let dashboard = store.dashboard(id) else { throw APIError.notFound("no dashboard \(id)") }
        let data = (try? JSONSerialization.data(withJSONObject: store.data(id), options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return DashboardDetail(dashboard: summary(dashboard), manifest: dashboard.manifest, script: dashboard.script, data: data,
                               problem: store.problems[id], undecided: store.undecided(id).sorted(), decided: store.wasDecided(id))
    }

    /// Every dashboard's saved state, for the pet to answer from.
    package func allData() -> [DashboardData] {
        store.dashboards.map { dashboard in
            let data = (try? JSONSerialization.data(withJSONObject: store.data(dashboard.id), options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return DashboardData(id: dashboard.id, title: dashboard.manifest.title, data: data)
        }
    }

    package func data(_ id: String) throws -> DashboardData {
        guard let dashboard = store.dashboard(id) else { throw APIError.notFound("no dashboard \(id)") }
        return allData().first { $0.id == id } ?? DashboardData(id: id, title: dashboard.manifest.title, data: "{}")
    }

    private func summary(_ dashboard: Dashboard) -> RemoteDashboard {
        let id = dashboard.id
        let undecided = store.undecided(id)
        let count = DashboardCount.value(showsCount: dashboard.manifest.showsCountFlag, reported: counts[id], data: store.data(id))
        return RemoteDashboard(id: id, title: dashboard.manifest.title, icon: dashboard.manifest.icon, color: dashboard.manifest.color,
                               showsCount: dashboard.manifest.showsCountFlag, count: count, approval: undecided.isEmpty ? "approved" : "pending",
                               capabilities: dashboard.manifest.capabilities.rows(newTokens: store.wasDecided(id) ? undecided : []))
    }

    /// Where a dashboard's code is, for "Edit code" in the window. Nil when there is no such dashboard.
    package func scriptFile(_ id: String) -> URL? { store.dashboard(id) == nil ? nil : store.paths.script(id) }

    /// The number on the icon of the dashboard, or nil.
    package func count(_ id: String) -> Int? { store.dashboard(id).flatMap { summary($0).count } }

    // MARK: Writing

    @discardableResult
    package func create(_ request: CreateDashboardRequest) throws -> RemoteDashboard {
        var manifest = DashboardManifest(title: request.title, icon: request.icon ?? "square.grid.2x2", color: request.color ?? "blue",
                                         count: request.count ?? false, capabilities: request.capabilities ?? DashboardCapabilities())
        manifest.title = manifest.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var id = request.id ?? DashboardValidator.slug(manifest.title)
        if request.id == nil {
            let base = id
            var n = 2
            while store.dashboard(id) != nil || FileManager.default.fileExists(atPath: store.paths.folder(id).path) {
                id = "\(String(base.prefix(36)))-\(n)"
                n += 1
            }
        }
        if let problem = DashboardRuntime.check(request.script) { throw APIError.invalid("the script does not work: \(problem)") }
        return summary(try store.create(id: id, manifest: manifest, script: request.script))
    }

    @discardableResult
    package func update(_ request: UpdateDashboardRequest) throws -> RemoteDashboard {
        guard let current = store.dashboard(request.id) else { throw APIError.notFound("no dashboard \(request.id)") }
        var manifest = current.manifest
        if let title = request.title { manifest.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let icon = request.icon { manifest.icon = icon }
        if let color = request.color { manifest.color = color }
        if let count = request.count { manifest.count = count }
        if let capabilities = request.capabilities { manifest.capabilities = capabilities }
        if let script = request.script, let problem = DashboardRuntime.check(script) { throw APIError.invalid("the script does not work: \(problem)") }
        try store.update(request.id, manifest: manifest, script: request.script)
        return summary(store.dashboard(request.id) ?? current)
    }

    /// The user picked another icon or colour. Not a change to the code, so it never asks for approval.
    package func setAppearance(id: String, icon: String?, color: String?) throws {
        guard let current = store.dashboard(id) else { throw APIError.notFound("no dashboard \(id)") }
        var manifest = current.manifest
        if let icon { manifest.icon = icon }
        if let color { manifest.color = color }
        try store.update(id, manifest: manifest)
    }

    package func delete(_ id: String) throws {
        try store.delete(id)
        counts[id] = nil
    }

    package func approve(_ id: String) throws { try store.approve(id) }

    package func deny(_ id: String) throws { try store.deny(id) }

    /// Merges `data` into the storage of a dashboard. An automation or an agent posts through this. A dashboard that does not exist
    /// refuses the post, which is how a deleted dashboard's automations stop feeding it.
    @discardableResult
    package func post(_ request: DashboardPostRequest) throws -> DashboardData {
        guard store.dashboard(request.id) != nil else { throw APIError.notFound("no dashboard \(request.id)") }
        guard let patch = (try? JSONSerialization.jsonObject(with: Data(request.data.utf8))) as? [String: Any] else {
            throw APIError.invalid("data must be a JSON object")
        }
        try store.merge(request.id, patch)
        return try data(request.id)
    }

    /// Posts an object from a script automation's `dashboard` action.
    package func post(id: String, patch: [String: Any]) throws {
        guard store.dashboard(id) != nil else { throw APIError.notFound("no dashboard \(id)") }
        try store.merge(id, patch)
    }

    // MARK: Running

    /// Runs the script and returns what it built. A script that fails gives the reason in `error`, not a thrown error.
    package func view(_ id: String) async throws -> RemoteDashboardView {
        guard let dashboard = store.dashboard(id) else { throw APIError.notFound("no dashboard \(id)") }
        let info = summary(dashboard)
        do {
            let rendered = try await DashboardRuntime.render(script: dashboard.script, data: store.data(id), allowed: store.allowed(id), host: runtimeHost())
            if let reported = rendered.count, counts[id] != max(0, reported) { counts[id] = max(0, reported) }
            return RemoteDashboardView(dashboard: summary(store.dashboard(id) ?? dashboard), root: rendered.root, updated: Date())
        } catch {
            return RemoteDashboardView(dashboard: info, error: error.localizedDescription, updated: Date())
        }
    }

    /// Runs the handler a view named. A data change and a prompt happen here. The rest comes back for the client to carry out.
    package func click(_ request: DashboardClickRequest) async throws -> RemoteDashboardClick {
        guard let dashboard = store.dashboard(request.id) else { throw APIError.notFound("no dashboard \(request.id)") }
        let clicked: DashboardRuntime.Clicked
        do {
            clicked = try await DashboardRuntime.click(script: dashboard.script, data: store.data(request.id), allowed: store.allowed(request.id),
                                                       host: runtimeHost(), handler: request.handler)
        } catch {
            return RemoteDashboardClick(error: error.localizedDescription)
        }
        var effects: [RemoteDashboardEffect] = []
        var problem: String?
        if !clicked.patch.isEmpty {
            do { try store.merge(request.id, clicked.patch) } catch { problem = error.localizedDescription }
        }
        for effect in clicked.effects {
            if effect.kind == "prompt", let text = effect.value {
                do { try await sources.prompt(text, request.id); effects.append(RemoteDashboardEffect(kind: "chat")) } catch { problem = error.localizedDescription }
            } else {
                effects.append(RemoteDashboardEffect(kind: effect.kind, value: effect.value))
            }
        }
        return RemoteDashboardClick(effects: effects, error: problem)
    }

    // MARK: Counts

    /// Reads the number each counting dashboard reports. A script's `count` needs a run, so this works in the background and the
    /// icons pick the numbers up as they arrive. Many changes in a row cost one run.
    package func scheduleCounts() {
        countTask?.cancel()
        countTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.refreshCounts()
        }
    }

    package func refreshCounts() async {
        for dashboard in store.dashboards where dashboard.manifest.showsCountFlag {
            guard let rendered = try? await DashboardRuntime.render(script: dashboard.script, data: store.data(dashboard.id), allowed: store.allowed(dashboard.id),
                                                                    host: runtimeHost(), deadline: 10) else { continue }
            let value = rendered.count.map { max(0, $0) }
            if counts[dashboard.id] != value { counts[dashboard.id] = value }
        }
        for gone in counts.keys where store.dashboard(gone) == nil { counts[gone] = nil }
    }
}

extension DashboardManifest {
    /// `count` in the manifest, named for what it means at the call sites.
    package var showsCountFlag: Bool { count }
}

#if canImport(Combine)
extension DashboardsAPI: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
