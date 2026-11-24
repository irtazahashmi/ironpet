import Foundation

/// Which tasks have a change on this phone that the Mac has not confirmed. The task sync queue (feat/ios-tasks-offline-sync) provides
/// the real answer; until it merges, nothing is pending, and its queue only has to conform to this protocol to light up the mark.
@MainActor
protocol PendingSyncSource {
    func isPendingSync(taskID: String) -> Bool
}

struct NoPendingSync: PendingSyncSource {
    func isPendingSync(taskID: String) -> Bool { false }
}
