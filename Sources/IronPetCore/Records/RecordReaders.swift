import Foundation

/// The readers behind `get`, one per kind that has an owner to ask. Each goes through the API that owns the kind, never a store, so a
/// record reads the same way it does in its own tool. A kind with no reader here (tasks, jobs, automations, filters) is read by the
/// tool that already exists for it. Memory pages and claims are read by the ref the memory store keeps, which is their key.
package enum RecordReaders {
    /// The readers, looking each owner up when a record is read: the screen API is attached after the database, so a reader holds a
    /// closure, not the API.
    @MainActor package static func make(screen: @escaping @MainActor () -> ScreenAPI?, notifications: @escaping @MainActor () -> NotificationsAPI?,
                                        meetings: @escaping @MainActor () -> MeetingsAPI?, chat: @escaping @MainActor () -> ChatAPI?,
                                        memory: @escaping @MainActor () -> MemoryAPI? = { nil },
                                        automations: @escaping @MainActor () -> AutomationsAPI? = { nil }) -> [RecordKind: RecordResolver.Reader] {
        [
            .page: { key in
                guard let memory = memory() else { return .failure(RecordError(message: "Ghost's memory is not available right now")) }
                guard let page = memory.pageRecord(ref: key) else { return .failure(RecordError(message: "no memory page with id \(key)")) }
                return .success(page)
            },
            .claim: { key in
                guard let memory = memory() else { return .failure(RecordError(message: "Ghost's memory is not available right now")) }
                guard let claim = memory.claimRecord(ref: key) else {
                    return .failure(RecordError(message: "no memory claim with id \(key); it may have been replaced or forgotten"))
                }
                return .success(claim)
            },
            .run: { key in
                guard let automations = automations() else { return .failure(RecordError(message: "automations are not available")) }
                guard let run = automations.runRecord(key) else {
                    return .failure(RecordError(message: "no automation run with id \(key); only the last runs of each automation are kept"))
                }
                return .success(run)
            },
            .screen: { key in
                guard let screen = screen() else { return .failure(RecordError(message: "screen capture is not available")) }
                guard let id = Int(key) else { return .failure(RecordError(message: "\(key) is not a capture id")) }
                switch screen.callTool("screen_window", ["id": id]) {
                case .success(let value):
                    guard let object = value as? [String: Any] else { return .failure(RecordError(message: "capture \(id) has no readable answer")) }
                    return .success(object)
                case .failure(let failure):
                    return .failure(RecordError(message: failure.message))
                }
            },
            .notif: { key in
                guard let notifications = notifications() else { return .failure(RecordError(message: "notifications are not available")) }
                do { return .success(try notifications.get(key).json(full: true)) } catch {
                    return .failure(RecordError(message: (error as? APIError)?.message ?? "no notification with id \(key)"))
                }
            },
            .meeting: { key in
                guard let meetings = meetings() else { return .failure(RecordError(message: "meetings are not available")) }
                do { return .success(object(try meetings.get(key))) } catch {
                    return .failure(RecordError(message: (error as? APIError)?.message ?? "no meeting with id \(key)"))
                }
            },
            .chat: { key in
                guard let chat = chat() else { return .failure(RecordError(message: "chat is not available")) }
                do { return .success(object(try await chat.thread(key).info)) } catch {
                    return .failure(RecordError(message: (error as? APIError)?.message ?? "no chat with id \(key)"))
                }
            },
            // A message is keyed by its thread and its item: `<thread>/<item>`.
            .msg: { key in
                guard let chat = chat() else { return .failure(RecordError(message: "chat is not available")) }
                guard let slash = key.firstIndex(of: "/") else { return .failure(RecordError(message: "\(key) is not a message")) }
                let thread = String(key[..<slash]), item = String(key[key.index(after: slash)...])
                do {
                    let items = try await chat.thread(thread).items
                    guard let found = items.first(where: { $0.id.uuidString == item }) else {
                        return .failure(RecordError(message: "no message with id \(key)"))
                    }
                    return .success(object(found))
                } catch {
                    return .failure(RecordError(message: (error as? APIError)?.message ?? "no chat with id \(thread)"))
                }
            },
        ]
    }

    /// A value as the JSON object `get` returns it. Dates are ISO 8601, as the rest of the API writes them.
    package static func object<T: Encodable>(_ value: T) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value), let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return dict
    }
}
