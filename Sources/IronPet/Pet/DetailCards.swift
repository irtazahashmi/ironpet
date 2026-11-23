import SwiftUI

// Building blocks for the card style of the detail pages: a card on material, a section with a header, a label and value row, and a chip.
// The task detail uses them first. Other detail views reuse them instead of drawing their own.

/// A frosted card: material under the content so the chat background doodles never sit behind text.
extension View {
    func cardMaterial() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A small caps title with an optional trailing action, over a card holding `content`.
struct CardSection<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    init(title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased()).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).tracking(0.5)
                Spacer()
                trailing().controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardMaterial()
        }
    }
}

struct SummaryRow<Value: View>: View {
    let label: String
    let symbol: String
    @ViewBuilder let value: () -> Value

    var body: some View {
        HStack(spacing: 8) {
            Label { Text(label) } icon: { Image(systemName: symbol).frame(width: 16) }
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Spacer(minLength: 8)
            value()
        }
        .font(.system(size: 13.5))
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
    }
}

/// A small tinted pill, such as a project, a status or a pull request key.
struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.18)))
    }
}
