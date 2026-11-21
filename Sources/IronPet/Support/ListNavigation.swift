import Foundation

/// Which row of a list is open in full. Nil shows the list. The list's filter and search live beside it, not in it, so
/// closing the detail page brings back the list as it was.
struct ListNavigation<ID: Hashable>: Equatable {
    private(set) var opened: ID?

    mutating func open(_ id: ID) { opened = id }
    mutating func close() { opened = nil }
}
