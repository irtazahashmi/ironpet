import Foundation

/// Moves the notes of the earlier builds (`me.md`, `people.md`, `projects/*.md` in `~/.ironpet/memory`) onto entity pages, once. Each
/// note becomes a claim with its own date and source. The files stay where they are and nothing reads them again. A launch that finds
/// no files still records the run, so the folder is not looked at again. A run that could not write is not recorded, and the next
/// launch tries again; a claim already written is skipped.
@MainActor
package enum MemoryMigration {
    /// The reflection cursor that marks the run done.
    package static let doneKey = "memory:entities-migrated"

    /// Runs the migration if it has not run. Returns how many claims it wrote.
    @discardableResult
    package static func run(into store: EntityMemoryStore, folder: URL = LegacyMemoryFiles.directory) -> Int {
        guard store.index.cursor(doneKey) == nil else { return 0 }
        var written = 0
        do {
            if let document = document(folder.appendingPathComponent("me.md")) {
                written += try store.importPage(id: "me", type: .me, name: "About me", identifiers: [], mentions: 0, notes: document.notes)
            }
            if let document = document(folder.appendingPathComponent("people.md")) {
                for section in document.sections {
                    let notes = document.entries.filter { $0.section == section }.map(\.note)
                    written += try store.importPage(id: EntityMatcher.personID(section), type: .person, name: section, identifiers: [],
                                                    mentions: max(EntityMemoryStore.stubMentions, notes.count), notes: notes)
                }
                // Lines from before people had sections are kept on their own page rather than attached to someone.
                let loose = document.entries.filter { $0.section == nil }.map(\.note)
                if !loose.isEmpty {
                    written += try store.importPage(id: "topic:people-notes", type: .topic, name: "People (unfiled notes)", identifiers: [],
                                                    mentions: EntityMemoryStore.stubMentions, notes: loose)
                }
            }
            let projects = folder.appendingPathComponent("projects")
            for url in (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "md" {
                guard let document = document(url), !document.notes.isEmpty else { continue }
                let key = projectKey(document)
                written += try store.importPage(id: "project:" + key.key, type: .project, name: key.name, identifiers: [key.key],
                                                mentions: EntityMemoryStore.stubMentions, notes: document.notes)
            }
        } catch {
            NSLog("ironpet: could not move the old notes onto pages, will retry at next launch: \(error.localizedDescription)")
            return written
        }
        // Indexes every claim for search and drops the old file notes' documents, so a partial earlier run leaves nothing unindexed.
        store.reindex()
        store.index.setCursor(doneKey, item: "1")
        return written
    }

    private static func document(_ url: URL) -> MemoryDocument? {
        (try? String(contentsOf: url, encoding: .utf8)).map(MemoryDocument.init)
    }

    /// The project a file was kept for. A `Workspace:` folder that is now a git repo joins the repo's page, as `migrateLayout` merged them.
    private static func projectKey(_ document: MemoryDocument) -> (key: String, name: String) {
        let title = document.lines.first { $0.hasPrefix("# ") }.map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) }
        if let repo = document.lines.first(where: { $0.hasPrefix("Repo: ") }) {
            let key = String(repo.dropFirst("Repo: ".count)).trimmingCharacters(in: .whitespaces)
            return (key, title?.isEmpty == false ? title! : key)
        }
        if let folder = document.lines.first(where: { $0.hasPrefix("Workspace: ") }) {
            let path = String(folder.dropFirst("Workspace: ".count)).trimmingCharacters(in: .whitespaces)
            let project = ProjectKey.of(URL(fileURLWithPath: path))
            return (project.key, project.name)
        }
        return (title ?? "project", title ?? "project")
    }
}
