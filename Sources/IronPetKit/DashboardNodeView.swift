#if canImport(SwiftUI)
import SwiftUI

public extension DashboardColors {
    /// The system colour a manifest's colour name stands for. An unknown name is blue.
    static func color(_ name: String) -> Color {
        switch name {
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "teal": return .teal
        case "gray": return .gray
        default: return .blue
        }
    }

    /// The colour of a node's `tone`. Nil is the primary text colour.
    static func tone(_ tone: String?) -> Color {
        switch tone {
        case "good": return .green
        case "warn": return .orange
        case "bad": return .red
        case "info": return .blue
        default: return .primary
        }
    }
}

/// Draws a dashboard's view tree with native SwiftUI components. The Mac window and the iPhone app both use it, so a dashboard
/// looks the same in both. `onAction` gets the id of the handler a click should run.
public struct DashboardNodeView: View {
    public let node: DashboardNode
    public let onAction: (String) -> Void

    public init(node: DashboardNode, onAction: @escaping (String) -> Void) {
        self.node = node
        self.onAction = onAction
    }

    public var body: some View {
        switch node.type {
        case "column":
            VStack(alignment: .leading, spacing: 12) { children }
        case "row":
            // Side by side when they fit, stacked when they do not (a phone).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) { equalChildren }
                VStack(alignment: .leading, spacing: 10) { children }
            }
        case "card":
            card
        case "text":
            text
        case "stat":
            stat
        case "list":
            list
        case "table":
            table
        case "chart":
            chart
        case "button":
            button
        case "divider":
            Divider()
        default:
            EmptyView()
        }
    }

    private var kids: [DashboardNode] { node.children ?? [] }

    private var children: some View {
        ForEach(Array(kids.enumerated()), id: \.offset) { _, child in DashboardNodeView(node: child, onAction: onAction) }
    }

    private var equalChildren: some View {
        ForEach(Array(kids.enumerated()), id: \.offset) { _, child in
            DashboardNodeView(node: child, onAction: onAction).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func tap<V: View>(_ action: String?, _ content: V) -> some View {
        Group {
            if let action {
                Button { onAction(action) } label: { content.contentShape(Rectangle()) }.buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var card: some View {
        tap(node.action, VStack(alignment: .leading, spacing: 8) {
            if node.text != nil || node.badge != nil {
                HStack(spacing: 6) {
                    if let title = node.text { Text(title).font(.system(size: 13, weight: .semibold)) }
                    Spacer(minLength: 6)
                    if let badge = node.badge { DashboardBadge(text: badge, tone: node.tone) }
                }
            }
            if let caption = node.caption { Text(caption).font(.system(size: 11)).foregroundStyle(.secondary) }
            children
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(SharedTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08))))
    }

    @ViewBuilder private var text: some View {
        let value = node.text ?? ""
        switch node.style {
        case "title": Text(value).font(.system(size: 22, weight: .bold)).foregroundStyle(DashboardColors.tone(node.tone))
        case "heading": Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(DashboardColors.tone(node.tone))
        case "caption": Text(value).font(.system(size: 11)).foregroundStyle(node.tone == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(DashboardColors.tone(node.tone)))
        case "code": Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(DashboardColors.tone(node.tone)).textSelection(.enabled)
        default: Text(value).font(.system(size: 13)).foregroundStyle(DashboardColors.tone(node.tone))
        }
    }

    private var stat: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label = node.label { Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            Text(node.value ?? "").font(.system(size: 26, weight: .bold)).foregroundStyle(DashboardColors.tone(node.tone))
            if let caption = node.caption { Text(caption).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(SharedTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(kids.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider() }
                tap(item.action, HStack(alignment: .top, spacing: 8) {
                    if let symbol = item.symbol { Image(systemName: symbol).foregroundStyle(DashboardColors.tone(item.tone)).frame(width: 18) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text ?? "").font(.system(size: 13, weight: .medium))
                        if let caption = item.caption { Text(caption).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 6)
                    if let badge = item.badge { DashboardBadge(text: badge, tone: item.tone) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 10))
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(SharedTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var table: some View {
        let columns = node.columns ?? []
        let rows = node.rows ?? []
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                if !columns.isEmpty {
                    GridRow { ForEach(Array(columns.enumerated()), id: \.offset) { _, name in Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) } }
                    Divider()
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(cell).font(.system(size: 12)) } }
                }
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(SharedTheme.card))
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = node.text { Text(title).font(.system(size: 12, weight: .semibold)) }
            DashboardChartShape(points: node.points ?? [], bars: node.chart == "bar")
                .frame(height: 90)
                .foregroundStyle(DashboardColors.tone(node.tone ?? "info"))
            if let labels = node.labels, !labels.isEmpty {
                HStack { ForEach(Array(labels.enumerated()), id: \.offset) { _, label in Text(label).font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity) } }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(SharedTheme.card))
    }

    @ViewBuilder private var button: some View {
        if let action = node.action {
            Button { onAction(action) } label: {
                HStack(spacing: 5) {
                    if let symbol = node.symbol { Image(systemName: symbol) }
                    Text(node.label ?? "")
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .tint(node.tone == nil ? nil : DashboardColors.tone(node.tone))
        }
    }
}

/// A short tag on a card or a list row.
public struct DashboardBadge: View {
    let text: String
    let tone: String?

    public init(text: String, tone: String?) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DashboardColors.tone(tone))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(DashboardColors.tone(tone).opacity(0.15)))
    }
}

/// The values of a chart drawn as a line or as bars, scaled to the frame. Zero is the bottom unless a value is negative.
struct DashboardChartShape: Shape {
    let points: [Double]
    let bars: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !points.isEmpty else { return path }
        let low = min(0, points.min() ?? 0), high = max(points.max() ?? 1, low + 1)
        func y(_ value: Double) -> CGFloat { rect.maxY - CGFloat((value - low) / (high - low)) * rect.height }
        if bars {
            let slot = rect.width / CGFloat(points.count)
            for (index, value) in points.enumerated() {
                let bar = CGRect(x: rect.minX + slot * CGFloat(index) + slot * 0.15, y: min(y(value), y(0)), width: slot * 0.7, height: abs(y(value) - y(0)))
                path.addRoundedRect(in: bar, cornerSize: CGSize(width: 2, height: 2))
            }
        } else {
            let step = points.count > 1 ? rect.width / CGFloat(points.count - 1) : 0
            for (index, value) in points.enumerated() {
                let point = CGPoint(x: points.count > 1 ? rect.minX + step * CGFloat(index) : rect.midX, y: y(value))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path = path.strokedPath(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        return path
    }
}

/// The symbols the icon picker lists, with the words that find them. The first group is what the picker suggests.
public enum DashboardSymbols {
    public static let all: [(symbol: String, words: String)] = [
        ("rectangle.split.3x1", "board kanban columns work"), ("square.grid.2x2", "grid apps dashboard"), ("chart.bar", "chart bars graph stats"),
        ("chart.line.uptrend.xyaxis", "chart line trend graph"), ("chart.pie", "chart pie share"), ("list.bullet", "list items todo"),
        ("tablecells", "table grid spreadsheet"), ("gauge.with.dots.needle.67percent", "gauge meter speed"),
        ("briefcase", "work job office"), ("hammer", "build tools fix"), ("terminal", "command shell code"), ("server.rack", "server host ops"),
        ("cloud", "cloud weather deploy"), ("arrow.triangle.branch", "git branch merge"), ("arrow.triangle.pull", "pull request git review"),
        ("bolt", "power fast energy"), ("shippingbox", "release package ship"), ("tag", "label version release"), ("flag", "milestone goal"),
        ("star", "favourite important"), ("flame", "hot trending fire"), ("leaf", "green health nature"), ("globe", "web world network"),
        ("calendar", "date schedule plan"), ("cart", "shop buy money"), ("creditcard", "money pay cost budget"), ("house", "home"),
        ("heart", "health love"), ("doc.text", "document notes write"), ("folder", "files project"), ("book", "read docs wiki"),
        ("cup.and.saucer", "coffee break"), ("tray", "inbox mail"), ("bell", "alerts notify"), ("person.2", "people team agents"),
        ("clock", "time hours timer"), ("checklist", "tasks done checks"), ("magnifyingglass", "search find"), ("lock", "security secret"),
        ("ant", "bug error"), ("wrench.and.screwdriver", "settings tools fix"), ("map", "location travel"), ("airplane", "travel flight"),
    ]

    /// The first group, shown above the rest.
    public static let suggested = Array(all.prefix(8))

    public static func matching(_ query: String) -> [(symbol: String, words: String)] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return all }
        return all.filter { entry in terms.allSatisfy { entry.symbol.lowercased().contains($0) || entry.words.contains($0) } }
    }
}
#endif
