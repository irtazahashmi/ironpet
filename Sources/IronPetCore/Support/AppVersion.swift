import Foundation

/// The version a build reports about itself, read from the bundle's Info dictionary.
/// `CFBundleShortVersionString` is the VERSION file, `CFBundleVersion` the build number, `IronPetGitCommit` the short
/// commit the bundling script embeds, and `IronPetDevBuild` is set by `scripts/install.sh` for a local build.
package struct AppVersion: Equatable {
    package var version: String
    package var build: String?
    package var commit: String?
    package var isDev: Bool

    package init(version: String, build: String? = nil, commit: String? = nil, isDev: Bool = false) {
        self.version = version
        self.build = build
        self.commit = commit
        self.isDev = isDev
    }

    package init(info: [String: Any]?) {
        func text(_ key: String) -> String? {
            guard let value = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        self.init(version: text("CFBundleShortVersionString") ?? "dev", build: text("CFBundleVersion"),
                  commit: text("IronPetGitCommit"), isDev: info?["IronPetDevBuild"] as? Bool ?? false)
    }

    /// "IronPet 0.1.2 (744b030)", "IronPet 0.1.2 dev (744b030)", or "IronPet 0.1.2" when the commit is unknown.
    package var label: String {
        var text = "IronPet \(version)"
        if isDev { text += " dev" }
        if let commit { text += " (\(commit))" }
        return text
    }

    /// What "Copy version" puts on the clipboard: the label, plus the build number when there is one.
    package var copyText: String {
        guard let build else { return label }
        return "\(label), build \(build)"
    }
}
