import Foundation

/// Which row of a list is open in full. Nil shows the list. The list's filter and search live beside it, not in it, so
/// closing the detail page brings back the list as it was.
package struct ListNavigation<ID: Hashable>: Equatable {
    package init(opened: ID? = nil) {
        self.opened = opened
    }

    package private(set) var opened: ID?

    package mutating func open(_ id: ID) { opened = id }
    package mutating func close() { opened = nil }
}
