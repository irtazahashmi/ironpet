import Foundation
import IronPetKit
import Observation

/// The audio files that wait on the phone for the Mac, and the work of sending them. The files are in the app group folder, which is
/// where the share extension puts them too, so a file shared while the app is closed is found here on the next launch.
@MainActor @Observable
final class MeetingUploadsModel {
    private(set) var pending: [PendingUpload] = []
    /// A line about a file that was not queued, such as the Mac's refusal text.
    var message: String?
    private(set) var sending = false

    @ObservationIgnored let queue: MeetingUploadQueue
    @ObservationIgnored private let transport: any MeetingUploadTransport
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Names the run that owns `task`, so a run that was cancelled and replaced does not clear its successor's state when it ends.
    @ObservationIgnored private var run = UUID()
    /// Called after the Mac confirmed a file, so the list of meetings reads again.
    @ObservationIgnored var onConfirmed: @MainActor () async -> Void = {}

    static let appGroup = "group.dev.ironpet.app"

    /// The folder shared with the share extension. Without the app group, such as in a build that is not signed for it, the app's own folder.
    static func defaultQueue() -> MeetingUploadQueue {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return MeetingUploadQueue(folder: base.appendingPathComponent("MeetingUploads", isDirectory: true))
    }

    init(queue: MeetingUploadQueue, transport: any MeetingUploadTransport, retryDelay: Duration = .seconds(30)) {
        self.queue = queue
        self.transport = transport
        self.retryDelay = retryDelay
        pending = queue.pending
    }

    var waiting: [PendingUpload] { pending.filter { $0.failure == nil } }
    var failed: [PendingUpload] { pending.filter { $0.failure != nil } }

    func reload() { pending = queue.pending }

    /// Queues the files the picker returned and starts sending. A file that is not m4a, mp3 or wav, or is over 1 GB, is refused with the
    /// Mac's own words and queues nothing.
    func add(_ urls: [URL]) {
        var refusals: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try queue.enqueue(copying: url) } catch { refusals.append((error as? MeetingUploadRefused)?.message ?? error.localizedDescription) }
        }
        message = refusals.isEmpty ? nil : refusals.joined(separator: "\n")
        reload()
        kick()
    }

    func dismiss(_ upload: PendingUpload) {
        queue.dismiss(upload.id)
        reload()
    }

    /// Sends what waits. It tries again after a pause while the Mac cannot be reached, and stops when nothing waits.
    func kick() {
        reload()
        guard task == nil, !waiting.isEmpty else { return }
        sending = true
        let mine = UUID()
        run = mine
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                let confirmed = await self.queue.drain(using: self.transport)
                self.reload()
                if confirmed > 0 { await self.onConfirmed() }
                if self.waiting.isEmpty { break }
                try? await Task.sleep(for: self.retryDelay)
            }
            guard let self, self.run == mine else { return }
            self.sending = false
            self.task = nil
        }
    }

    /// Tries at once, for the moments the Mac may be reachable again: the app came to the front, or the connection came back.
    func retryNow() {
        guard task != nil else { kick(); return }
        task?.cancel()
        task = nil
        kick()
    }

    func stop() {
        task?.cancel()
        task = nil
        sending = false
    }
}
