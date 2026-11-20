import IronPetKit
import SwiftUI

struct TasksView: View {
    let model: TasksModel
    @State private var showDone = false

    var body: some View {
        NavigationStack {
            List {
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityIdentifier("tasks-error")
                }
                if !model.suggestions.isEmpty {
                    Section { ForEach(model.suggestions) { SuggestionRow(suggestion: $0, model: model) } } header: { header("Suggestions", id: "suggestions") }
                }
                taskSection("Needs you", id: "needs-you", model.needsYou)
                taskSection("In progress", id: "in-progress", model.inProgress)
                taskSection("Backlog", id: "backlog", model.backlog)
                taskSection("Waiting on others", id: "waiting", model.waiting)
                if !model.done.isEmpty {
                    Section {
                        Button { withAnimation { showDone.toggle() } } label: {
                            HStack {
                                Image(systemName: "chevron.right").rotationEffect(.degrees(showDone ? 90 : 0)).foregroundStyle(.secondary)
                                Text("Done (\(model.done.count))").font(.headline)
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("section-done")
                        .accessibilityValue(showDone ? "Expanded" : "Collapsed")
                        if showDone { ForEach(model.done) { row($0) } }
                    }
                }
                if model.loaded, model.tasks.isEmpty, model.suggestions.isEmpty {
                    ContentUnavailableView("No tasks", systemImage: "checklist", description: Text("Tasks you add on the Mac show up here."))
                }
            }
            .navigationTitle("Tasks")
            .refreshable { await model.reload() }
            .navigationDestination(for: RemoteTask.self) { TaskDetailView(model: model, task: $0) }
        }
        .task { model.start() }
    }

    private func header(_ title: String, id: String) -> some View {
        Text(title).textCase(nil).font(.headline).foregroundStyle(.primary).accessibilityIdentifier("section-\(id)")
    }

    @ViewBuilder private func taskSection(_ title: String, id: String, _ items: [RemoteTask]) -> some View {
        if !items.isEmpty {
            Section { ForEach(items) { row($0) } } header: { header(title, id: id) }
        }
    }

    private func row(_ task: RemoteTask) -> some View {
        NavigationLink(value: task) { TaskRow(task: task) }.accessibilityIdentifier("task-\(task.id)")
    }
}

struct TaskRow: View {
    let task: RemoteTask

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title).strikethrough(task.status == .done)
            if let line = detail { Text(line).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let waiting = task.waitingOn { parts.append("Waiting on \(waiting)") }
        if let due = task.due { parts.append("Due \(due.formatted(date: .abbreviated, time: .omitted))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct SuggestionRow: View {
    let suggestion: RemoteSuggestion
    let model: TasksModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(suggestion.title)
            Text(origin).font(.caption).foregroundStyle(.secondary)
            if !suggestion.notes.isEmpty { Text(suggestion.notes).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            HStack {
                Button("Add") { Task { await model.add(suggestion) } }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("add-\(suggestion.id)")
                Button("Skip") { Task { await model.skip(suggestion) } }
                    .buttonStyle(.bordered).accessibilityIdentifier("skip-\(suggestion.id)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("suggestion-\(suggestion.id)")
    }

    private var origin: String {
        var text = suggestion.origin == "meeting" ? "Meeting" : (suggestion.originDetail.map { "From \($0)" } ?? "Automation")
        if let waiting = suggestion.waitingOn { text += " · Waiting on \(waiting)" }
        if let due = suggestion.due { text += " · Due \(due)" }
        return text
    }
}
