import Foundation

/// A title and speaker names that the summary agent proposed for a room or imported meeting. The user accepts or
/// corrects them on the Mac. They live in `suggestions.json` in the meeting folder until then, and an accepted title is
/// `title.txt`. A meeting folder keeps no voice data, so nothing here can identify anyone by sound.
package struct MeetingSuggestions: Codable, Equatable {
    package init(title: String? = nil, speakers: [String: String] = [:]) {
        self.title = title
        self.speakers = speakers
    }

    package var title: String?
    /// The transcript label of a voice (`Speaker 2`) and the name proposed for it.
    package var speakers: [String: String]

    package var isEmpty: Bool { title == nil && speakers.isEmpty }

    package static let fileName = "suggestions.json"
    package static let titleFileName = "title.txt"
    package static let heading = "## Suggestions"
    package static let maxTitleLength = 120
    package static let maxNameLength = 60

    /// Splits the agent's answer into the summary and the suggestions section at its end. An answer without the
    /// section comes back unchanged with no suggestions.
    package static func parse(_ answer: String) -> (summary: String, suggestions: MeetingSuggestions) {
        let lines = answer.components(separatedBy: "\n")
        guard let start = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == heading.lowercased() }) else {
            return (answer, MeetingSuggestions())
        }
        var result = MeetingSuggestions()
        for line in lines[(start + 1)...] {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = clean(String(line[line.index(after: colon)...]))
            guard !value.isEmpty else { continue }
            if key.lowercased() == "title" {
                result.title = String(value.prefix(maxTitleLength))
            } else if isSpeakerLabel(key), isUsableName(value) {
                result.speakers[key] = String(value.prefix(maxNameLength))
            }
        }
        let summary = lines[..<start].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (summary, result)
    }

    /// Keeps only the voices that speak in `transcript`, so a made-up label never reaches the Mac's list.
    package func limited(toTranscript transcript: String) -> MeetingSuggestions {
        var copy = self
        copy.speakers = speakers.filter { SpeakerRename.hasSpeaker($0.key, in: transcript) }
        return copy
    }

    package static func load(_ folder: URL) -> MeetingSuggestions {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              let value = try? JSONDecoder().decode(MeetingSuggestions.self, from: data) else { return MeetingSuggestions() }
        return value
    }

    /// Writes the file, or removes it when there is nothing left to suggest.
    package func save(to folder: URL) {
        let url = folder.appendingPathComponent(Self.fileName)
        guard !isEmpty else { try? FileManager.default.removeItem(at: url); return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(self) { try? data.write(to: url, options: .atomic) }
    }

    /// The accepted title of a meeting, or nil.
    package static func title(in folder: URL) -> String? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(titleFileName), encoding: .utf8) else { return nil }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Stores a title for the meeting. An empty title removes it.
    package static func setTitle(_ title: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(titleFileName)
        let clean = String(clean(title).prefix(maxTitleLength))
        if clean.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try (clean + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "\n", with: " ")
        let quotes = CharacterSet(charactersIn: "\"'`")
        return value.trimmingCharacters(in: quotes.union(.whitespaces))
    }

    private static func isSpeakerLabel(_ key: String) -> Bool {
        let parts = key.split(separator: " ")
        return parts.count == 2 && parts[0] == "Speaker" && Int(parts[1]) != nil
    }

    private static func isUsableName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return !["me", "them", "none", "none.", "unknown", "n/a"].contains(lower) && !lower.hasPrefix("speaker ")
    }
}
