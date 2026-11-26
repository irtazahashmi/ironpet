import AppKit
import IronPetCore
import IronPetKit
import SwiftUI

/// The Today section: the morning brief or the day's recap, one row per thing to look at. A row opens its task, session,
/// alert or meeting.
struct TodayView: View {
    @ObservedObject var model: BriefModel
    @Binding var kind: Brief.Kind
    let onOpen: (Brief.Target) -> Void

    @State private var search = ""

    var body: some View {
        ListScreen(title: IronPetSection.today.title, search: $search, trailing: {
            Picker("Show", selection: Binding(get: { kind }, set: { kind = $0; model.picked() })) {
                ForEach(Brief.Kind.allCases) { Text($0.pickerTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Brief or recap")
        }) {
            content
        }
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
    }

    /// The items of a brief whose title or subtitle contain `query`. Sections left empty are dropped.
    static func filter(_ sections: [Brief.Section], query: String) -> [Brief.Section] {
        sections.compactMap { section in
            var kept = section
            kept.items = ListSearch.filter(section.items, query: query, title: \.title, description: \.subtitle)
            return kept.items.isEmpty ? nil : kept
        }
    }

    @ViewBuilder private var content: some View {
        if let brief = model.briefs[kind], !brief.isEmpty {
            let sections = Self.filter(brief.sections, query: search)
            if sections.isEmpty {
                NoMatches()
            } else {
                ListScroll {
                    Text(Self.dateLine(kind, kind == .recap ? brief.window.start : brief.window.end))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                    ForEach(sections) { section in
                        ListGroupTitle(section.title)
                        ForEach(section.items) { item in
                            BriefRow(item: item, onOpen: onOpen)
                        }
                    }
                }
            }
        } else {
            EmptyState(symbol: kind.symbol, title: kind.emptyText, detail: Self.emptyDetail(kind))
        }
    }

    /// "Morning brief · Tuesday 17 November".
    static func dateLine(_ kind: Brief.Kind, _ date: Date) -> String {
        "\(kind.title) · \(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))"
    }

    static func emptyDetail(_ kind: Brief.Kind) -> String {
        switch kind {
        case .brief: return "Alerts, action items from meetings and agents waiting on you show up here."
        case .recap: return "Finished agent turns, resolved alerts and meetings from today show up here."
        }
    }
}

/// A row opens the session, alert or meeting it names in that section, which is its detail page.
private struct BriefRow: View {
    let item: Brief.Item
    let onOpen: (Brief.Target) -> Void

    var body: some View {
        ListRow(title: item.title, description: item.subtitle, onOpen: { onOpen(item.target) },
                leading: { ListRowIcon(symbol: item.symbol, color: tint) },
                extra: { EmptyView() },
                trailing: { hovering in
                    Image(systemName: SharedSymbols.chevron)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0)
                        .accessibilityHidden(true)
                })
        .help(help)
        .accessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(help)
        .contextMenu {
            if case .alert(let id, let url?) = item.target {
                Button("Open Link") { NSWorkspace.shared.open(url) }
                Button("Show in Alerts") { onOpen(.alert(id: id, url: nil)) }
            }
        }
    }

    private var tint: Color {
        switch item.symbol {
        case "xmark.octagon.fill", "calendar.badge.exclamationmark": return .red
        case "hand.raised.fill", "person.fill.questionmark": return .orange
        case "checkmark.circle.fill", "checkmark.circle", "checkmark.seal.fill": return .green
        default: return .accentColor
        }
    }

    private var help: String {
        switch item.target {
        case .session: return "Open the session"
        case .alert(_, let url): return url == nil ? "Show in Alerts" : "Open the link"
        case .meeting: return "Open the meeting"
        }
    }
}
