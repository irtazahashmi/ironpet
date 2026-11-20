import SwiftUI

/// A system notice in the transcript: one muted line naming its source. A click shows the rest of the text as markdown.
struct SystemNoticeRow: View {
    let text: String
    @State private var expanded = false

    private var label: String { text.components(separatedBy: "\n").first ?? text }
    private var detail: String { text.dropFirst(label.count).trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if !detail.isEmpty { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape").font(.system(size: 10))
                    Text(label).font(.system(size: 11.5))
                    if !detail.isEmpty { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)) }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            if expanded {
                Text((try? AttributedString(markdown: detail, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(detail))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
