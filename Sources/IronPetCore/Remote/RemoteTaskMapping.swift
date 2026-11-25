import Foundation
import IronPetKit

/// The `IronPetKit` form of the core's task types, which is what the task routes encode. The core has its own `TaskStatus` and `TaskLink`,
/// so the Kit ones are named with the module.
extension RemoteTask {
    package init(_ item: TaskItem) {
        self.init(id: item.id, title: item.title, notes: item.notes, status: IronPetKit.TaskStatus(rawValue: item.status.rawValue) ?? .backlog,
                  source: item.source.rawValue, due: item.due, closed: item.closed, waitingOn: item.waitingOn,
                  links: item.links.map { IronPetKit.TaskLink(kind: $0.kind.rawValue, ref: $0.ref, label: $0.label) }, labels: item.labels,
                  created: item.created, updated: item.updated, sourceRef: item.sourceRef.map { RemoteJSON(reference: $0) }, ref: item.ref)
    }
}

extension RemoteTaskEvent {
    package init(_ event: TaskEvent) {
        self.init(at: event.at, by: event.by, kind: event.kind.rawValue, detail: event.detail)
    }
}

extension RemoteSuggestion {
    package init(_ suggestion: TaskSuggestion) {
        let origin: String, detail: String
        switch suggestion.origin {
        case .meeting(let folder): origin = "meeting"; detail = folder.path
        case .automation(let id, let name): origin = "automation"; detail = "\(name) (\(id))"
        case .taskScan: origin = "task-scan"; detail = "Task scan"
        }
        self.init(id: suggestion.id, title: suggestion.title, created: suggestion.created, origin: origin, originDetail: detail, due: suggestion.due,
                  notes: suggestion.notes, url: suggestion.url?.absoluteString, waitingOn: suggestion.waitingOn,
                  sourceRef: suggestion.sourceRef.map { RemoteJSON(reference: $0) }, update: suggestion.update?.remote)
    }
}
