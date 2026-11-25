import Foundation

/// Which question a form card shows. A form with one page has no arrows and no indicator. The Mac card and the iPhone card share it.
public struct ElicitationPager: Equatable, Sendable {
    public let pageCount: Int
    public private(set) var index = 0

    public init(pageCount: Int) { self.pageCount = max(pageCount, 1) }

    public var isPaged: Bool { pageCount > 1 }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < pageCount - 1 }
    public var isLast: Bool { !canGoForward }
    public var label: String { "\(index + 1) of \(pageCount)" }

    public mutating func back() { if canGoBack { index -= 1 } }
    public mutating func forward() { if canGoForward { index += 1 } }
    public mutating func show(_ page: Int) { index = min(max(page, 0), pageCount - 1) }
}

/// How a form's fields group into pages, by field id. The Mac form and the iPhone form both use it.
public enum ElicitationPaging {
    /// Positions of the fields on each page, one page per question. A `question_<n>_custom` field joins the page of the
    /// field right before it, so a question and its Other box stay together. Only AskUserQuestion forms are paged:
    /// when any id is not `question_<n>` or `question_<n>_custom`, all fields share one page.
    public static func pages(ids: [String]) -> [[Int]] {
        guard ids.allSatisfy({ $0.range(of: #"^question_\d+(_custom)?$"#, options: .regularExpression) != nil }) else {
            return [Array(ids.indices)]
        }
        var result: [[Int]] = []
        for (position, id) in ids.enumerated() {
            if id.hasSuffix("_custom"), let last = result.last?.first, id == ids[last] + "_custom" {
                result[result.count - 1].append(position)
            } else {
                result.append([position])
            }
        }
        return result
    }
}
