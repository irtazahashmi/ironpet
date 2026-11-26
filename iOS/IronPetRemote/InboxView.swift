import IronPetKit
import SwiftUI

struct InboxView: View {
    let model: InboxModel

    var body: some View {
        NavigationStack {
            List {
                Group {
                    ForEach(model.items) { InboxRow(item: $0, model: model) }
                    if model.loaded, model.items.isEmpty, !model.lastRefreshFailed {
                        ContentUnavailableView("Inbox is empty", systemImage: SharedSymbols.tasks, description: Text("Items from meetings and automations show up here."))
                    }
                }
                .listRowBackground(SharedTheme.card)
            }
            .refreshable { await model.reload() }
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .themedScreen()
            .fullPageLoadError(model)
            .alert("Could not update the Inbox", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .task { model.start() }
    }
}

struct InboxRow: View {
    let item: RemoteSuggestion
    let model: InboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(item.sourceLinks.enumerated()), id: \.element.id) { index, link in
                Link(link.label, destination: link.url).font(.caption).accessibilityIdentifier(index == 0 ? "source-\(item.id)" : "source-\(item.id)-\(index)")
            }
            if !item.notes.isEmpty { Text(item.notes).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            HStack {
                Button("Done") { Task { await model.done(item) } }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("done-\(item.id)")
                Button("Remove") { Task { await model.remove(item) } }
                    .buttonStyle(.bordered).accessibilityIdentifier("remove-\(item.id)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox-\(item.id)")
    }

    private var subtitle: String {
        let from = item.sources.count > 1 ? "\(item.originLabel) and \(item.sources.count - 1) more" : item.originLabel
        return "\(from) · \(item.created.formatted(.relative(presentation: .named)))"
    }
}
