import IronPetCore
import SwiftUI

/// What the detail panel of an inbox item shows. Only fields that have a value appear, so the view never draws an empty label.
struct TaskDetail: Equatable {
    struct Field: Equatable {
        var label: String
        var value: String
    }

    var fields: [Field] = []
    var notes = ""
    var links: [TaskLink] = []

    /// `{"ref": "...", "reason": "..."}` becomes Ref and Reason fields. Other objects list their keys, and plain text stays as it is.
    static func originFields(_ sourceRef: String?) -> [Field] {
        guard let text = sourceRef?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        func rank(_ key: String) -> Int { key == "ref" ? 0 : key == "reason" ? 1 : 2 }
        guard let object = TaskJSON.refValue(text) as? [String: Any] else { return [Field(label: "Origin ref", value: text)] }
        let keys = object.keys.sorted { (rank($0), $0) < (rank($1), $1) }
        return keys.compactMap { key in
            let value = (object[key] as? String) ?? "\(object[key] ?? "")"
            guard !value.isEmpty else { return nil }
            return Field(label: key == "ref" ? "Origin ref" : key == "reason" ? "Origin reason" : "Origin \(key)", value: value)
        }
    }

    init(suggestion: TaskSuggestion) {
        if let due = suggestion.due, !due.isEmpty { fields.append(Field(label: "Due", value: due)) }
        fields.append(Field(label: "Origin", value: suggestion.source.rawValue))
        fields.append(Field(label: "Origin name", value: suggestion.originLabel))
        fields += Self.originFields(suggestion.sourceRef)
        fields.append(Field(label: "Arrived", value: Self.time(suggestion.created)))
        notes = suggestion.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        links = suggestion.links
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
    }
}

/// Everything stored about an inbox item. Notes render as markdown in selectable text, and links open only on a click.
struct TaskDetailView: View {
    let detail: TaskDetail
    let onOpen: (TaskLink) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 3) {
                    ForEach(Array(detail.fields.enumerated()), id: \.offset) { _, field in
                        GridRow {
                            Text(field.label).foregroundStyle(.secondary)
                            Text(field.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.caption)
                if !detail.notes.isEmpty {
                    MarkdownView(text: detail.notes, size: 12)
                }
                if !detail.links.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(detail.links.enumerated()), id: \.offset) { _, link in
                            Button { onOpen(link) } label: {
                                Label(TaskLinkRow(link: link).title, systemImage: link.symbol)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .buttonStyle(.link)
                            .help(link.help)
                        }
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: true)
    }
}
