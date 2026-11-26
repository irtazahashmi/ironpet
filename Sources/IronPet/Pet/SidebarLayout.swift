import Foundation

/// The order of the sidebar's sections and which ones the user hid. Both are kept per Mac in UserDefaults.
///
/// `order` lists section ids, hidden ones included, so a section that is shown again returns to its place. A saved
/// order that predates a section lists it nowhere, so it is appended; an id that no longer exists is dropped.
struct SidebarLayout: Equatable {
    static let orderKey = "ironpetSidebarOrder"
    static let hiddenKey = "ironpetSidebarHidden"

    /// The only section that cannot be hidden.
    static let pinned: IronPetSection = .chat

    private(set) var order: [String]
    private(set) var hidden: Set<String>

    init(order: [String] = [], hidden: Set<String> = []) {
        self.order = order
        self.hidden = hidden.subtracting([Self.pinned.rawValue])
    }

    init(defaults: UserDefaults) {
        self.init(order: defaults.stringArray(forKey: Self.orderKey) ?? [],
                  hidden: Set(defaults.stringArray(forKey: Self.hiddenKey) ?? []))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(order, forKey: Self.orderKey)
        defaults.set(hidden.sorted(), forKey: Self.hiddenKey)
    }

    /// Every known section in the saved order, then the ones the saved order does not mention, in their default order.
    private var full: [IronPetSection] {
        var seen = Set<IronPetSection>()
        var result: [IronPetSection] = []
        for id in order {
            if let section = IronPetSection(rawValue: id), seen.insert(section).inserted { result.append(section) }
        }
        for section in IronPetSection.allCases where seen.insert(section).inserted { result.append(section) }
        return result
    }

    func isHidden(_ section: IronPetSection) -> Bool {
        section != Self.pinned && hidden.contains(section.rawValue)
    }

    /// The available sections in the user's order, hidden ones included. The right-click menu lists these.
    func arranged(_ available: [IronPetSection]) -> [IronPetSection] {
        full.filter(available.contains)
    }

    /// The available sections the sidebar draws. ⌘1 to ⌘9 index into this list.
    func visible(_ available: [IronPetSection]) -> [IronPetSection] {
        arranged(available).filter { !isHidden($0) }
    }

    /// Shows or hides a section. Chat stays shown.
    mutating func setHidden(_ section: IronPetSection, _ hide: Bool) {
        guard section != Self.pinned else { return }
        if hide { hidden.insert(section.rawValue) } else { hidden.remove(section.rawValue) }
        order = full.map(\.rawValue)
    }

    /// Moves rows of the visible list, with the offsets and destination of SwiftUI's `onMove`. Hidden sections keep
    /// their slots, so they return to the same place when shown again.
    mutating func moveVisible(from offsets: IndexSet, to destination: Int, in available: [IronPetSection]) {
        var rows = visible(available)
        rows.move(fromOffsets: offsets, toOffset: destination)
        place(rows)
    }

    /// Moves `section` to the row of `target`, or to the end when `target` is nil.
    mutating func move(_ section: IronPetSection, before target: IronPetSection?, in available: [IronPetSection]) {
        var rows = visible(available)
        guard let from = rows.firstIndex(of: section) else { return }
        rows.remove(at: from)
        let to = target.flatMap { rows.firstIndex(of: $0) } ?? rows.count
        rows.insert(section, at: to)
        place(rows)
    }

    /// Writes `rows` into the slots the visible available sections occupy.
    private mutating func place(_ rows: [IronPetSection]) {
        var slots = full
        let slotIndexes = slots.indices.filter { index in rows.contains(slots[index]) }
        for (index, section) in zip(slotIndexes, rows) { slots[index] = section }
        order = slots.map(\.rawValue)
    }
}
