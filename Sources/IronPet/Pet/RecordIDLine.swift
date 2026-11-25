import AppKit
import SwiftUI

/// A record's public id, such as `task_9f3c1e`, with a button that copies it. Detail pages show it under the date, so a person can paste
/// the id into a chat or a note, where it becomes a link back to the record.
struct RecordIDLine: View {
    let ref: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Text(ref)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ref, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Copy the id")
            .accessibilityLabel(copied ? "Copied" : "Copy id")
        }
        .accessibilityElement(children: .contain)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
        .onChange(of: ref) { copied = false }
    }
}
