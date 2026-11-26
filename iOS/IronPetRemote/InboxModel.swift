import Foundation
import IronPetKit
import Observation

/// The Inbox tab: what the Mac collected for the person (meeting follow-ups, automation finds), each one done or removed from here.
@MainActor @Observable
final class InboxModel: SocketModel {
    private(set) var items: [RemoteSuggestion] = []
    /// Ids the person has finished or removed. A read that was already in flight when they did it must not bring them back.
    @ObservationIgnored private var hidden: Set<String> = []

    override func reload() async {
        // A Mac that has no inbox route, or that answers it with an error or with something this phone cannot read, is a Mac on another
        // version. The phone shows an empty Inbox for it. Only a failure to reach the Mac counts as a failed read.
        let list = await read { () async throws -> [RemoteSuggestion] in
            do {
                return try await self.client.suggestions()
            } catch ClientError.api(_, _, _), ClientError.invalidResponse {
                return []
            }
        }
        guard let list else { return }
        hidden.formIntersection(list.map(\.id))
        items = list.filter { !hidden.contains($0.id) }
    }

    override func handle(_ event: RemoteEvent) async {
        if event.kind == RemoteEvent.suggestionsChanged { debouncer.run("inbox") { [weak self] in await self?.reload() } }
    }

    /// Marks the item done on the Mac.
    func done(_ item: RemoteSuggestion) async { await take(item) { try await self.client.acceptSuggestion(id: item.id) } }

    /// Removes the item on the Mac.
    func remove(_ item: RemoteSuggestion) async { await take(item) { try await self.client.rejectSuggestion(id: item.id) } }

    /// Takes the item off the list at once and puts it back, with the reason in `errorMessage`, when the Mac does not take the change.
    private func take(_ item: RemoteSuggestion, _ call: () async throws -> Void) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        hidden.insert(item.id)
        do {
            try await call()
            network.reportAnswered()
            errorMessage = nil
        } catch ClientError.api(404, _, _) {
            // The item was already gone on the Mac, which is what the person asked for.
            network.reportAnswered()
        } catch {
            hidden.remove(item.id)
            items.insert(item, at: min(index, items.count))
            if error is CancellationError { return }
            if error as? ClientError == .unauthorized { return onUnauthorized() }
            network.report(error)
            errorMessage = error.localizedDescription
        }
    }
}

extension RemoteSuggestion {
    /// "Meeting", or "From <automation name>". An older Mac may still send another origin, such as `task-scan`, which reads as an automation.
    var originLabel: String {
        if origin == "meeting" { return "Meeting" }
        if let name = originDetail?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return "From \(name)" }
        return "From an automation"
    }

    /// The link to the source. A meeting's source is a folder on the Mac, which the phone cannot open, so a meeting has none.
    var sourceLink: URL? {
        guard origin != "meeting", let url, let link = URL(string: url), ["http", "https"].contains(link.scheme?.lowercased()) else { return nil }
        return link
    }
}
