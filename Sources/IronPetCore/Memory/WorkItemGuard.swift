import Foundation

/// Deterministic checks that back the memory rules for what a page is. The model is told the rules in the prompts, and these checks
/// refuse what it still gets wrong, so the tests do not depend on model output.
package enum WorkItemGuard {
    private static let kinds = "pr|prs|pull request|pull-request|mr|merge request|issue|ticket|bug|task|story|epic|gh"

    /// Page names that are a work item: a Jira key (`SSP-10435`), a bare or hash-prefixed number (`#304`, `304`), a kind with a
    /// reference (`PR 12`, `issue #304`), a repo reference (`ironpet#304`, `owner/repo#12`) or a link to an issue, PR or ticket.
    /// A Jira key needs at least two digits, so a tool name such as `GPT-4` stays a valid page name.
    private static let nameShapes: [NSRegularExpression] = [
        "^(?i:(?:\(kinds))[\\s:#-]*)?#?\\d+$",
        "^[\\w.\\-/]*#\\d+$",
        "/(?:issues|pull|pulls|merge_requests|browse)/[A-Za-z0-9-]*\\d+",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Whether a proposed page name is a ticket, issue or PR reference. Takes the name as the model wrote it, before `#` is stripped.
    package static func isWorkItem(_ name: String?) -> Bool {
        guard let name else { return false }
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        if jiraKey(text) { return true }
        return nameShapes.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    private static func jiraKey(_ text: String) -> Bool {
        let pattern = "^[A-Z][A-Z0-9]+-\\d{2,}$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        // The kind word ("ticket SSP-10435") may be in any case; the key itself must be upper case.
        let stripped = text.replacingOccurrences(of: "^(?i:(?:\(kinds))[\\s:#-]*)", with: "", options: .regularExpression)
        let range = NSRange(stripped.startIndex..., in: stripped)
        return regex.firstMatch(in: stripped, range: range) != nil
    }

    private static let reference = try? NSRegularExpression(
        pattern: "\\b[A-Z][A-Z0-9]+-\\d{2,}\\b|#\\d+|\\b(?:pr|pull request|merge request|mr|issue|ticket|task)s?\\s*\\d+\\b|"
            + "\\b(?:the|this|that|a|an|my|our|its)\\s+(?:pr|pull request|merge request|mr|issue|ticket|task)\\b",
        options: [.caseInsensitive])

    private static let state = try? NSRegularExpression(
        pattern: "\\b(?:waiting (?:for|on)|awaiting|in progress|in review|under review|ready for review|needs review|(?:is|was|got|been|gets) merged|"
            + "(?:is|was|got|been) (?:open|opened|closed|reopened|blocked|done|approved|rejected|rebased|reverted)|still (?:open|failing|pending))\\b",
        options: [.caseInsensitive])

    /// Whether a note only says where one task stands (a PR waiting for review, a ticket in progress, an issue merged). That is not a
    /// lasting fact, so the digest does not keep it.
    package static func isTaskState(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        guard let reference, let state else { return false }
        return reference.firstMatch(in: text, range: range) != nil && state.firstMatch(in: text, range: range) != nil
    }
}
