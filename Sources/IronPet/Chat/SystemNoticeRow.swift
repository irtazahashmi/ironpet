import IronPetCore
import IronPetKit
import SwiftUI

/// A system notice in the transcript: one muted line naming its source. A click shows the rest of the text as markdown.
/// It draws through `ChatSystemRow`, the same line as the tool-step row, so the two share one leading edge and chevron.
struct SystemNoticeRow: View {
    let text: String
    @State private var expanded = false

    private var notice: ChatNotice { ChatNotice(text) }

    var body: some View {
        ChatSystemRow(expanded: expanded, canExpand: !notice.detail.isEmpty, label: Text(notice.label),
                      toggle: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } },
                      icon: { Image(systemName: SharedSymbols.settings) },
                      detail: {
            Text((try? AttributedString(markdown: notice.detail, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(notice.detail))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SharedTheme.card, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 2)
        })
    }
}
