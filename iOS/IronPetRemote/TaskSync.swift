import CryptoKit
import Foundation
import IronPetKit

/// One task change the user made on the phone that the Mac has not confirmed yet. The record is what gets written to disk, so it holds
/// the text of the change and the copy it was based on, and nothing the phone knows about the pairing.
struct TaskOp: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case create, status, edit, close }

    /// The client id. The Mac applies a change with this id once, so a replay after a lost answer changes nothing.
    var id: UUID
    var kind: Kind
    /// The task the change is for. A created task has a local id until the Mac answers, and later changes to it are renamed then.
    var taskID: String
    var queuedAt: Date
    /// The new title, notes or status the change sets. A nil field is left as it is. A close sets the status to done.
    var title: String?
    var notes: String?
    var status: TaskStatus?
    /// The note that goes to the task history with a status change or a close.
    var note: String = ""
    /// The `updated` time and the field values of the copy the user edited. They tell a replay what the Mac changed in the meantime.
    var baseUpdated: Date?
    var baseTitle: String?
    var baseNotes: String?
    var baseStatus: TaskStatus?

    static func localID(_ id: UUID) -> String { "local-" + id.uuidString.lowercased() }
    static func isLocal(_ taskID: String) -> Bool { taskID.hasPrefix("local-") }

    /// Starts a change from the copy the user is looking at.
    static func make(_ kind: Kind, on task: RemoteTask, id: UUID = UUID(), now: Date = Date()) -> TaskOp {
        TaskOp(id: id, kind: kind, taskID: task.id, queuedAt: now, status: kind == .close ? .done : nil, baseUpdated: task.updated,
               baseTitle: task.title, baseNotes: task.notes, baseStatus: task.status)
    }

    /// The change to a task as the phone shows it before the Mac has answered.
    func applied(to task: RemoteTask, now: Date) -> RemoteTask {
        var task = task
        switch kind {
        case .create: break
        case .status:
            if let status { task.status = status }
            task.closed = task.status == .done ? (task.closed ?? now) : nil
        case .edit:
            if let title { task.title = title }
            if let notes { task.notes = notes }
        case .close:
            task.status = .done
            task.closed = task.closed ?? now
        }
        return task
    }

    /// The task a create adds while it waits.
    func created() -> RemoteTask {
        RemoteTask(id: taskID, title: title ?? "", notes: notes ?? "", status: status ?? .backlog, source: "user", created: queuedAt, updated: queuedAt)
    }

    /// Which fields of this change the Mac changed after the phone read it. Those fields are not sent: the Mac's value stays.
    func droppingFieldsChanged(onTheMac mac: RemoteTask) -> TaskOp {
        var op = self
        if let baseTitle, mac.title != baseTitle { op.title = nil }
        if let baseNotes, mac.notes != baseNotes { op.notes = nil }
        if let baseStatus, mac.status != baseStatus { op.status = nil }
        op.baseUpdated = mac.updated
        op.baseTitle = mac.title
        op.baseNotes = mac.notes
        op.baseStatus = mac.status
        return op
    }

    /// True when nothing is left to send after `droppingFieldsChanged`.
    var isEmpty: Bool {
        switch kind {
        case .create: return false
        case .status: return status == nil
        case .edit: return title == nil && notes == nil
        case .close: return status == nil
        }
    }
}

/// The last task list and quick filters the Mac sent, so the Tasks tab has something to show before the Mac answers.
struct TaskSnapshot: Codable, Equatable {
    var tasks: [RemoteTask]
    var filters: [QuickFilter]
    var filtersSupported: Bool
}

/// Where the task list and the waiting changes live between launches.
protocol TaskSyncStoring: AnyObject {
    func loadSnapshot() -> TaskSnapshot?
    func saveSnapshot(_ snapshot: TaskSnapshot)
    func loadOps() -> [TaskOp]
    func saveOps(_ ops: [TaskOp])
}

/// Two JSON files in the app's own Application Support folder, left out of backups and out of the shared app group. The names carry a
/// hash of the device token, so tasks cached for one Mac never show for another after a new pairing. Files of earlier pairings are deleted.
final class FileTaskSyncStore: TaskSyncStoring {
    private let snapshotURL: URL
    private let opsURL: URL

    init(snapshotURL: URL, opsURL: URL) {
        self.snapshotURL = snapshotURL
        self.opsURL = opsURL
    }

    private static var folder: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    static func forToken(_ token: String?, folder: URL = FileTaskSyncStore.folder) -> FileTaskSyncStore {
        let hash = SHA256.hash(data: Data((token ?? "").utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let keep: Set<String> = ["tasksync-list-\(hash).json", "tasksync-ops-\(hash).json"]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for old in names where old.hasPrefix("tasksync-") && !keep.contains(old) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
        return FileTaskSyncStore(snapshotURL: folder.appendingPathComponent("tasksync-list-\(hash).json"), opsURL: folder.appendingPathComponent("tasksync-ops-\(hash).json"))
    }

    /// Deletes the cached tasks and waiting changes of every pairing. An unpaired phone keeps nothing of the Mac's list.
    static func clearAll(folder: URL = FileTaskSyncStore.folder) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("tasksync-") { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }

    func loadSnapshot() -> TaskSnapshot? { read(TaskSnapshot.self, snapshotURL) }
    func saveSnapshot(_ snapshot: TaskSnapshot) { write(snapshot, snapshotURL) }

    func loadOps() -> [TaskOp] { read([TaskOp].self, opsURL) ?? [] }

    func saveOps(_ ops: [TaskOp]) {
        if ops.isEmpty {
            try? FileManager.default.removeItem(at: opsURL)
        } else {
            write(ops, opsURL)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? WireJSON.makeDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? WireJSON.makeEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = url
        try? excluded.setResourceValues(values)
    }
}

/// Keeps both in memory. Tests share one between two models to stand for a relaunch.
final class MemoryTaskSyncStore: TaskSyncStoring {
    private(set) var snapshot: TaskSnapshot?
    private(set) var ops: [TaskOp]

    init(snapshot: TaskSnapshot? = nil, ops: [TaskOp] = []) {
        self.snapshot = snapshot
        self.ops = ops
    }

    func loadSnapshot() -> TaskSnapshot? { snapshot }
    func saveSnapshot(_ snapshot: TaskSnapshot) { self.snapshot = snapshot }
    func loadOps() -> [TaskOp] { ops }
    func saveOps(_ ops: [TaskOp]) { self.ops = ops }
}
