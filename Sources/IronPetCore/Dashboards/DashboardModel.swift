import Foundation
import IronPetKit

/// What a dashboard asks the user to allow. A dashboard declares these in its manifest, the user approves them, and the host API
/// refuses everything that is not both declared and approved.
///
/// ```json
/// {"run": ["gh pr list", "gh pr view"], "network": ["api.github.com"], "read": ["inbox", "agents"], "write": ["inbox"], "prompt": true}
/// ```
package struct DashboardCapabilities: Codable, Equatable {
    package init(run: [String] = [], network: [String] = [], read: [String] = [], write: [String] = [], prompt: Bool = false) {
        self.run = run
        self.network = network
        self.read = read
        self.write = write
        self.prompt = prompt
    }

    /// Command lines the script may run, each a prefix: `gh pr list` allows `gh pr list --json number`. No shell is involved.
    package var run: [String]
    /// Hosts the script may fetch from over http or https.
    package var network: [String]
    /// IronPet data the script may read: `inbox`, `alerts`, `agents`.
    package var read: [String]
    /// IronPet data the script may change: `inbox` (mark an item done or remove it).
    package var write: [String]
    /// Whether a click may send the pet a prompt.
    package var prompt: Bool

    package static let readable = ["inbox", "alerts", "agents"]
    package static let writable = ["inbox"]

    package var isEmpty: Bool { tokens.isEmpty }

    /// One string per single permission, such as `run:gh pr list` or `network:api.github.com`. Approval works on these, so a
    /// dashboard that adds one command to a list it already had asks again for that command only.
    package var tokens: Set<String> {
        var set = Set<String>()
        for command in run { set.insert("run:\(command)") }
        for host in network { set.insert("network:\(host.lowercased())") }
        for name in read { set.insert("read:\(name)") }
        for name in write { set.insert("write:\(name)") }
        if prompt { set.insert("prompt") }
        return set
    }

    enum CodingKeys: String, CodingKey { case run, network, read, write, prompt }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        run = try c.decodeIfPresent([String].self, forKey: .run) ?? []
        network = try c.decodeIfPresent([String].self, forKey: .network) ?? []
        read = try c.decodeIfPresent([String].self, forKey: .read) ?? []
        write = try c.decodeIfPresent([String].self, forKey: .write) ?? []
        prompt = try c.decodeIfPresent(Bool.self, forKey: .prompt) ?? false
    }

    /// The five rows of the approval sheet. `newTokens` marks the kinds that hold something not approved yet.
    package func rows(newTokens: Set<String>) -> [RemoteDashboardCapability] {
        func isNew(_ prefix: String) -> Bool { newTokens.contains { $0 == prefix || $0.hasPrefix(prefix + ":") } }
        var rows: [RemoteDashboardCapability] = []
        if !run.isEmpty {
            rows.append(.init(kind: "run", title: "Run commands", detail: run.joined(separator: ", ") + ". Runs as you, without a shell.", isNew: isNew("run")))
        }
        if !network.isEmpty {
            rows.append(.init(kind: "network", title: "Reach the network", detail: "Hosts: " + network.joined(separator: ", ") + ".", isNew: isNew("network")))
        }
        if !read.isEmpty {
            rows.append(.init(kind: "read", title: "Read IronPet data", detail: "Reads " + read.joined(separator: ", ") + ".", isNew: isNew("read")))
        }
        if !write.isEmpty {
            rows.append(.init(kind: "write", title: "Change IronPet data", detail: "Changes " + write.joined(separator: ", ") + ".", isNew: isNew("write")))
        }
        if prompt {
            rows.append(.init(kind: "prompt", title: "Prompt the pet", detail: "Buttons can send the pet a message. Each one shows in Chat as sent by the dashboard.", isNew: isNew("prompt")))
        }
        return rows
    }
}

/// `manifest.json`: everything about a dashboard except its code and its data.
package struct DashboardManifest: Codable, Equatable {
    package init(title: String, icon: String = "square.grid.2x2", color: String = "blue", count: Bool = false,
                 capabilities: DashboardCapabilities = DashboardCapabilities()) {
        self.title = title
        self.icon = icon
        self.color = color
        self.count = count
        self.capabilities = capabilities
    }

    package var title: String
    /// An SF Symbol name.
    package var icon: String
    package var color: String
    /// Whether the sidebar icon shows a number: what the script's `count` returns, else the `count` in its data.
    package var count: Bool
    package var capabilities: DashboardCapabilities

    enum CodingKeys: String, CodingKey { case title, icon, color, count, capabilities }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "square.grid.2x2"
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "blue"
        count = try c.decodeIfPresent(Bool.self, forKey: .count) ?? false
        capabilities = try c.decodeIfPresent(DashboardCapabilities.self, forKey: .capabilities) ?? DashboardCapabilities()
    }
}

/// A dashboard as it is on disk: `<id>/manifest.json` and `<id>/main.js`.
package struct Dashboard: Equatable, Identifiable {
    package init(id: String, manifest: DashboardManifest, script: String) {
        self.id = id
        self.manifest = manifest
        self.script = script
    }

    package var id: String
    package var manifest: DashboardManifest
    package var script: String
}

/// What the user has decided about one dashboard's capabilities.
package struct DashboardApproval: Codable, Equatable {
    package init(approved: Set<String> = [], denied: Set<String> = []) {
        self.approved = approved
        self.denied = denied
    }

    package var approved: Set<String>
    package var denied: Set<String>
}

package enum DashboardValidator {
    package static let maxScriptBytes = 128 * 1024
    package static let maxTitle = 60
    package static let maxCommands = 30
    package static let maxHosts = 20
    package static let maxCommandLength = 200

    /// The one reason a manifest or script is not acceptable, or nil.
    package static func problem(manifest m: DashboardManifest, script: String) -> String? {
        if m.title.trimmingCharacters(in: .whitespaces).isEmpty { return "title is empty" }
        if m.title.count > maxTitle { return "title is longer than \(maxTitle) characters" }
        if !isSymbolName(m.icon) { return "icon must be an SF Symbol name such as chart.bar" }
        if !DashboardColors.names.contains(m.color) { return "color must be one of \(DashboardColors.names.joined(separator: ", "))" }
        if script.utf8.count > maxScriptBytes { return "the script is longer than \(maxScriptBytes / 1024) KiB" }
        let c = m.capabilities
        if c.run.count > maxCommands { return "at most \(maxCommands) commands in capabilities.run" }
        for command in c.run {
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed != command || command.count > maxCommandLength { return "capabilities.run has an empty or too long command" }
            if command.contains(where: { $0.isNewline }) { return "a command in capabilities.run has a line break" }
        }
        if c.network.count > maxHosts { return "at most \(maxHosts) hosts in capabilities.network" }
        for host in c.network where !isHost(host) { return "\"\(host)\" is not a host name such as api.github.com" }
        for name in c.read where !DashboardCapabilities.readable.contains(name) {
            return "capabilities.read allows \(DashboardCapabilities.readable.joined(separator: ", ")), not \"\(name)\""
        }
        for name in c.write where !DashboardCapabilities.writable.contains(name) {
            return "capabilities.write allows \(DashboardCapabilities.writable.joined(separator: ", ")), not \"\(name)\""
        }
        return nil
    }

    package static func isSymbolName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }
    }

    package static func isHost(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 253 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
            && !text.hasPrefix(".") && !text.hasSuffix(".")
    }

    /// A folder name made from a title: lowercase letters, digits and dashes.
    package static func slug(_ text: String) -> String {
        var out = ""
        for ch in text.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) } else if !out.hasSuffix("-") && !out.isEmpty { out.append("-") }
        }
        let trimmed = String(out.drop { $0 == "-" }.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "dashboard" : trimmed
    }

    package static func isID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 40 && text.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") } && !text.hasPrefix("-")
    }
}

/// The number on a dashboard's sidebar icon.
package enum DashboardCount {
    /// Nil when the manifest asks for no number. Otherwise `reported`, the number the script's `count` gave, else the `count` in the
    /// data (a whole number, zero or more). A dashboard with neither has no number yet.
    package static func value(showsCount: Bool, reported: Int?, data: [String: Any]) -> Int? {
        guard showsCount else { return nil }
        if let reported { return max(0, reported) }
        if let whole = data["count"] as? Int { return max(0, whole) }
        if let fraction = data["count"] as? Double, fraction.isFinite { return max(0, Int(fraction)) }
        return nil
    }
}
