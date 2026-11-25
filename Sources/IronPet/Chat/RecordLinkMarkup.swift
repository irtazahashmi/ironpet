import Foundation
import IronPetKit

/// Links record ids in a chat's Markdown. This needs `AttributedString`'s Markdown attributes, which Linux's Foundation lacks, so it
/// lives in the Mac app and not in `IronPetKit`, which CI also builds on Linux.
extension RecordLinks {
    /// Links each id in `text` that is not already a link and not code. The text itself does not change.
    static func link(_ text: AttributedString) -> AttributedString {
        let plain = String(text.characters)
        guard plain.contains("_") else { return text }
        var result = text
        for match in detect(in: plain) {
            let offset = plain.distance(from: plain.startIndex, to: match.range.lowerBound)
            let length = plain.distance(from: match.range.lowerBound, to: match.range.upperBound)
            let lower = result.characters.index(result.characters.startIndex, offsetBy: offset)
            let upper = result.characters.index(lower, offsetBy: length)
            let runs = result[lower..<upper].runs
            guard runs.allSatisfy({ $0.link == nil && !isCode($0) }), let url = url(for: match.id) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }

    /// Whether a run is a code span from Markdown.
    private static func isCode(_ run: AttributedString.Runs.Run) -> Bool {
        let intent: InlinePresentationIntent? = run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self]
        return intent?.contains(.code) == true
    }
}
