#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Sizes shared by the quiet one-line rows in a transcript: "Ran 2 commands" and "Automation: Task review".
public enum ChatSystemRowMetrics {
    /// Both rows start where an assistant reply's text starts (24 pt pet face and an 8 pt gap).
    public static let leading: CGFloat = 32
    public static let iconColumn: CGFloat = 14
    public static let spacing: CGFloat = 6
    public static let verticalPadding: CGFloat = 4
    public static let fontSize: CGFloat = 11.5
    public static let chevronSize: CGFloat = 9
}

/// One quiet line in the transcript: an icon in a fixed column, a label, then a chevron that turns when the row is open.
/// The tool-step row and the notice row both draw through this, so they share the leading edge, the icon column, the
/// baseline, the height and the chevron position. `detail` shows under the line while `expanded` is set.
public struct ChatSystemRow<Icon: View, Detail: View>: View {
    let expanded: Bool
    /// False for a row with nothing to open: the chevron is hidden and a tap does nothing.
    let canExpand: Bool
    let scale: CGFloat
    let identifier: String
    let label: Text
    let icon: Icon
    let toggle: () -> Void
    let detail: Detail
    @State private var hovering = false

    public init(expanded: Bool, canExpand: Bool = true, scale: CGFloat = 1, identifier: String = "", label: Text,
                toggle: @escaping () -> Void, @ViewBuilder icon: () -> Icon, @ViewBuilder detail: () -> Detail) {
        self.expanded = expanded
        self.canExpand = canExpand
        self.scale = scale
        self.identifier = identifier
        self.label = label
        self.toggle = toggle
        self.icon = icon()
        self.detail = detail()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { if canExpand { toggle() } }) {
                HStack(spacing: ChatSystemRowMetrics.spacing) {
                    icon.frame(width: ChatSystemRowMetrics.iconColumn * scale)
                    label.lineLimit(1).truncationMode(.middle)
                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(.system(size: ChatSystemRowMetrics.chevronSize * scale, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .opacity(hovering || expanded ? 1 : 0.6)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: ChatSystemRowMetrics.fontSize * scale))
                .foregroundStyle(hovering && canExpand ? .primary : .secondary)
                .padding(.vertical, ChatSystemRowMetrics.verticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                hovering = inside
                #if canImport(AppKit)
                if canExpand { if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                #endif
            }
            .accessibilityIdentifier(identifier)
            if expanded { detail }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, ChatSystemRowMetrics.leading)
    }
}

/// The status mark of one tool step: a spinner while it runs, then a green check or a red cross.
public struct ChatStepIcon: View {
    let ok: Bool?

    public init(_ ok: Bool?) { self.ok = ok }

    public var body: some View {
        switch ok {
        case nil: ChatStepSpinner().frame(width: 12, height: 12)
        case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case false?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// A small rotating arc for a running step. An indeterminate `ProgressView` starts a threaded AppKit animation that parks a
/// global dispatch worker for as long as it is on screen, so a transcript with many running steps used up the shared pool.
/// This one is drawn by SwiftUI on the main thread.
public struct ChatStepSpinner: View {
    let size: CGFloat

    public init(size: CGFloat = 10) { self.size = size }

    public var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
        }
        .frame(width: size, height: size)
    }
}

/// The mark on the folded tool line: a spinner while a step runs, an orange warning when one failed, a check otherwise.
public struct ChatToolRunIcon: View {
    let state: ChatToolSteps.State

    public init(_ state: ChatToolSteps.State) { self.state = state }

    public var body: some View {
        switch state {
        case .running: ChatStepIcon(nil)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        }
    }
}

/// The card under an open row: the steps of a tool run, one per line with a hairline between them.
public struct ChatStepList<Row: View>: View {
    let count: Int
    let row: (Int) -> Row

    public init(count: Int, @ViewBuilder row: @escaping (Int) -> Row) {
        self.count = count
        self.row = row
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                if index > 0 { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1) }
                row(index)
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        .padding(.top, 2)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
#endif
