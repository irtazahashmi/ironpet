import Foundation
import IronPetKit
import Observation

/// How far back the change list reaches. The raw value is what the Mac's `since` takes.
enum ScreenRange: String, CaseIterable, Identifiable {
    case hour = "1h", today = "today", threeDays = "3d"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hour: return "Last hour"
        case .today: return "Today"
        case .threeDays: return "3 days"
        }
    }
}

/// The Screen screen: status, the change list, outlines, search and pause. Nothing is read from the Mac while it is locked. Everything
/// that came from the Mac lives in this object only: it is never written to disk, and locking drops it. The client keeps no URL cache.
@MainActor @Observable
final class ScreenModel: SocketModel {
    private(set) var status: RemoteScreenStatus?
    private(set) var windows: [RemoteScreenWindow] = []
    private(set) var hits: [RemoteScreenHit] = []
    /// What the last search asked for, so an empty result can say so.
    private(set) var searched: String?
    private(set) var captures: [Int: RemoteScreenCapture] = [:]
    /// The Mac answered 403: this device lacks the screen scope, which only the Mac grants.
    private(set) var forbidden = false
    var range: ScreenRange = .today
    var notice: String?
    let gate: TranscriptGate

    init(client: IronPetClient, events: any EventSignalSource, gate: TranscriptGate? = nil, onUnauthorized: @escaping () -> Void) {
        let gate = gate ?? TranscriptGate(reason: "Show screen text")
        self.gate = gate
        super.init(client: client, events: events, onUnauthorized: onUnauthorized)
        gate.onLock = { [weak self] in self?.forget() }
    }

    /// Drops everything that came from the Mac.
    private func forget() {
        status = nil
        windows = []
        hits = []
        searched = nil
        captures = [:]
        notice = nil
        forbidden = false
        errorMessage = nil
    }

    func unlock() async {
        await gate.unlock()
        if gate.isUnlocked { await refresh() }
    }

    override func reload() async {
        guard gate.isUnlocked else { return }
        if let current = await call({ try await self.client.screenStatus() }), gate.isUnlocked { status = current }
        guard !forbidden else { return }
        if let list = await call({ try await self.client.screenChanges(since: self.range.rawValue) }), gate.isUnlocked { windows = list }
    }

    /// Runs one request. A 403 means the scope is off, which the screen explains instead of showing an error line.
    private func call<T>(_ request: () async throws -> T) async -> T? {
        do {
            let value = try await request()
            forbidden = false
            errorMessage = nil
            return value
        } catch ClientError.api(let status, _, _) where status == 403 {
            forbidden = true
            errorMessage = nil
            return nil
        } catch ClientError.api(let status, _, _) where status == 429 {
            errorMessage = "Too many screen requests. Try again in a few minutes."
            return nil
        } catch {
            return await run { throw error }
        }
    }

    func setRange(_ next: ScreenRange) async {
        range = next
        guard gate.isUnlocked else { return }
        if let list = await call({ try await self.client.screenChanges(since: next.rawValue) }), gate.isUnlocked { windows = list }
    }

    func search(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard gate.isUnlocked else { return }
        guard !query.isEmpty else { hits = []; searched = nil; return }
        if let found = await call({ try await self.client.screenSearch(query) }), gate.isUnlocked {
            hits = found
            searched = query
        }
    }

    func clearSearch() {
        hits = []
        searched = nil
    }

    /// The outline or text of one capture, or nil when the screen is locked or the capture is gone.
    func capture(_ id: Int) async -> RemoteScreenCapture? {
        guard gate.isUnlocked else { return nil }
        if let held = captures[id] { return held }
        guard let fetched = await call({ try await self.client.screenCapture(id: id) }), gate.isUnlocked else { return nil }
        captures[id] = fetched
        return fetched
    }

    func pause(minutes: Int?) async {
        guard gate.isUnlocked else { return }
        let result: RemoteScreenStatus?
        if let minutes { result = await call { try await self.client.pauseScreen(minutes: minutes) } } else {
            result = await call { try await self.client.pauseScreenUntilTomorrow() }
        }
        if let result, gate.isUnlocked {
            status = result
            notice = "Capture is paused. Resume it on the Mac."
        }
    }
}
