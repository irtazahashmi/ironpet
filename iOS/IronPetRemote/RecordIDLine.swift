import SwiftUI
import UIKit

/// A record's public id, such as `task_9f3c1e`, with a button that copies it. Detail screens show it near the top, so a person can paste
/// the id into a chat, where it becomes a link back to the record.
struct RecordIDLine: View {
    let ref: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 2) {
            Text(ref)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = ref
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.footnote)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(copied ? "Copied" : "Copy id")
            .accessibilityIdentifier("copy-record-id")
        }
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
        .onChange(of: ref) { copied = false }
    }
}
