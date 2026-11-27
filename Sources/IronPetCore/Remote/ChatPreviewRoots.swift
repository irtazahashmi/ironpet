import Foundation

/// The folders a chat's agent works in, which is where the phone may preview files from.
package enum ChatPreviewRoots {
    /// The extra folders IronPet gives every agent as `additionalDirectories`. `ACPBackend` sends this list, so the two cannot drift.
    package static var ironPetExtraFolders: [URL] { [Paths.screenshots] }

    /// The main folder, IronPet's extra folders, and for the Claude agent the `permissions.additionalDirectories` of its settings files.
    /// The scratch folder of a general question and the recent folders are not roots. A folder that is `/` or the home folder is dropped.
    package static func compute(
        folder: String?, agentId: String, home: String = NSHomeDirectory(), extraFolders: [URL] = ironPetExtraFolders
    ) -> [String] {
        var candidates: [String] = []
        if let folder, folder != ChatSession.scratchWorkspace.path { candidates.append(folder) }
        candidates += extraFolders.map(\.path)
        if agentId == "claude" {
            var files = [home + "/.claude/settings.json"]
            if let folder, !folder.isEmpty {
                files += [folder + "/.claude/settings.json", folder + "/.claude/settings.local.json"]
            }
            let project = folder ?? home
            for file in files { candidates += claudeDirectories(in: file, project: project, home: home) }
        }
        let homePath = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
        var seen = Set<String>()
        return candidates.filter { path in
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            guard resolved != "/", resolved != homePath else { return false }
            return seen.insert(path).inserted
        }
    }

    private static func claudeDirectories(in file: String, project: String, home: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = object["permissions"] as? [String: Any],
              let list = permissions["additionalDirectories"] as? [Any] else { return [] }
        return list.compactMap { $0 as? String }.compactMap { raw in
            let entry = raw.trimmingCharacters(in: .whitespaces)
            if entry.isEmpty { return nil }
            if entry == "~" { return home }
            if entry.hasPrefix("~/") { return home + entry.dropFirst() }
            if entry.hasPrefix("/") { return entry }
            return project + "/" + entry
        }
    }
}
