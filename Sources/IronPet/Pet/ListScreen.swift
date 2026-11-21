import AppKit
import IronPetCore
import SwiftUI

/// The layout every section of the ironpet window shares, so the lists look and behave the same:
///
/// - `ListScreen` is the section: a title row with the filters and a search field on the right.
/// - `ListScroll` is the scrolling body, a centered column no wider than `ListScreenMetrics.maxWidth`.
/// - `ListRow` is one row: a title, a one-line description, and actions on the right.
/// - `ListDetailPage` is what a click on a row opens, with a Back button. `ListNavigation` holds which row is open.
/// - `ListSearch` is the matching rule the search field uses in every section.

enum ListScreenMetrics {
    /// The widest a section's content gets. The chat column uses the same number, so a list lines up with the chat.
    static let maxWidth: CGFloat = ChatView.columnWidth
    /// Space between the window edge and the content once the window is narrower than `maxWidth`.
    static let gutter: CGFloat = 16
}

// MARK: - Search

enum ListSearch {
    /// Whether `query` appears in any of `fields`, ignoring case and accents. An empty query matches everything.
    static func matches(_ query: String, in fields: [String?]) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return fields.contains { $0?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The items whose title or description contains `query`.
    static func filter<T>(_ items: [T], query: String, title: (T) -> String?, description: (T) -> String?) -> [T] {
        items.filter { matches(query, in: [title($0), description($0)]) }
    }
}

// MARK: - Column

/// Where a section's content column was laid out, in window coordinates. A test compares it with `ListScreenMetrics.maxWidth`.
struct ListColumnFrame: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = value ?? nextValue() }
}

private struct ListColumn: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: ListScreenMetrics.maxWidth, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ListColumnFrame.self, value: proxy.frame(in: .global))
                }
            }
            .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Limits the view to `ListScreenMetrics.maxWidth` and centers it.
    func listColumn() -> some View { modifier(ListColumn()) }
}

// MARK: - Screen

/// A section of the window: the title row, with the section's filters and a search field right-aligned in it, over `content`.
/// `content` scrolls inside a `ListScroll`, or draws a `listColumn()` of its own.
struct ListScreen<Trailing: View, Content: View>: View {
    let title: String
    /// The search text. Nil for a section with nothing to search.
    var search: Binding<String>?
    /// Hides the filters and the search field while a row is open in full.
    var detailOpen = false
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .pageHeader(title) {
                if !detailOpen {
                    HStack(spacing: 10) {
                        trailing()
                        if let search { ListSearchField(text: search, label: title) }
                    }
                }
            }
    }
}

extension ListScreen where Trailing == EmptyView {
    init(title: String, search: Binding<String>? = nil, detailOpen: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, search: search, detailOpen: detailOpen, trailing: { EmptyView() }, content: content)
    }
}

struct ListSearchField: View {
    @Binding var text: String
    /// The section's title, for the accessibility label.
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityLabel("Search \(label)")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: 170)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

/// The scrolling body of a list: a column of rows, centered, with the scroll bar at the window's edge.
struct ListScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) { content() }
                .padding(.horizontal, ListScreenMetrics.gutter)
                .padding(.vertical, 12)
                .listColumn()
        }
        .frame(maxHeight: .infinity)
    }
}

/// What a list shows when the search or a filter hides every row.
struct NoMatches: View {
    var body: some View {
        EmptyState(symbol: "magnifyingglass", title: "Nothing matches", detail: "No row has that text in its title or description.")
    }
}

// MARK: - Row

/// One row of a list, in the style of the Automations rows: a leading icon or control, a title with a one-line
/// description under it, and actions on the right. Clicking the row calls `onOpen`.
struct ListRow<Leading: View, Extra: View, Trailing: View>: View {
    let title: String
    var description: String?
    var emphasized = false
    var dimmed = false
    var onOpen: (() -> Void)?
    @ViewBuilder let leading: () -> Leading
    /// More lines under the description, such as a status or a row of small buttons.
    @ViewBuilder let extra: () -> Extra
    /// The actions on the right. The flag says the pointer is over the row.
    @ViewBuilder let trailing: (Bool) -> Trailing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leading()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: emphasized ? .semibold : .medium))
                    .foregroundStyle(dimmed ? .secondary : .primary)
                    .lineLimit(1)
                if let description, !description.isEmpty, description != title {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                extra()
            }
            Spacer(minLength: 4)
            trailing(hovering)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering && onOpen != nil ? 0.09 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onOpen?() }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAction(named: "Show details") { onOpen?() }
    }
}

extension ListRow where Leading == EmptyView, Extra == EmptyView {
    init(title: String, description: String? = nil, emphasized: Bool = false, dimmed: Bool = false, onOpen: (() -> Void)? = nil,
         @ViewBuilder trailing: @escaping (Bool) -> Trailing) {
        self.init(title: title, description: description, emphasized: emphasized, dimmed: dimmed, onOpen: onOpen,
                  leading: { EmptyView() }, extra: { EmptyView() }, trailing: trailing)
    }
}

/// The icon at the left of a row, in the 18 pt slot every row uses.
struct ListRowIcon: View {
    let symbol: String
    var color: Color = .secondary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .padding(.top, 1)
            .accessibilityHidden(true)
    }
}

/// A group title between rows, such as "Needs you".
struct ListGroupTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        SectionTitle(text).padding(.horizontal, 2)
    }
}

// MARK: - Detail

/// The Back button over a detail page. Esc does the same.
struct ListBackBar: View {
    /// The section the button returns to, such as "Tasks".
    let section: String
    let onBack: () -> Void

    var body: some View {
        HStack {
            Button(action: onBack) { Label(section, systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Back to \(section)")
                .help("Back to the list (Esc)")
            Spacer()
        }
        .padding(.horizontal, ListScreenMetrics.gutter - 2)
        .padding(.vertical, 6)
        .listColumn()
    }
}

/// A row in full. `ListDetailPage` is the detail for sections that have no page of their own: the Back button over a
/// scrolling, centered column.
struct ListDetailPage<Content: View>: View {
    let section: String
    let onBack: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ListBackBar(section: section, onBack: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content() }
                    .padding(.horizontal, ListScreenMetrics.gutter + 4)
                    .padding(.vertical, 14)
                    .listColumn()
            }
        }
    }
}

/// A label over a value, for the detail pages that list a row's fields.
struct DetailField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
