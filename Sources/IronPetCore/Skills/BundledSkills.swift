#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A skill that ships with ironpet: a folder `skills/<name>/SKILL.md` in the repo, compiled into the app by
/// `scripts/gen_skills.py`. To add one, add the folder, run the script, and it shows up in Settings, the CLI and the install bubble.
package struct BundledSkill: Equatable {
    package init(name: String, content: String) {
        self.name = name
        self.content = content
    }

    package let name: String
    package let content: String

    package var hash: String { SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// The frontmatter `description`.
    package var description: String {
        content.components(separatedBy: "\n").first { $0.hasPrefix("description: ") }.map { String($0.dropFirst("description: ".count)) } ?? ""
    }

    /// The first sentence of the description, for lists.
    package var summary: String {
        let text = description
        guard let end = text.firstIndex(of: ".") else { return text }
        return String(text[..<end])
    }
}

package enum BundledSkills {
    package static let all: [BundledSkill] = BundledSkillsData.all.map { BundledSkill(name: $0.name, content: $0.content) }

    package static func named(_ name: String) -> BundledSkill? { all.first { $0.name == name } }
}
