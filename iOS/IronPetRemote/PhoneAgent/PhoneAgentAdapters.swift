import EventKit
import Foundation
import IronPetKit

/// Streams a provider's answer with `URLSession`. A status other than 2xx throws the provider's own message.
struct URLSessionAgentTransport: AgentTransport {
    let session: URLSession

    init(session: URLSession = URLSessionAgentTransport.makeSession()) { self.session = session }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func lines(for request: AgentHTTPRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var urlRequest = URLRequest(url: request.url)
                urlRequest.httpMethod = "POST"
                urlRequest.httpBody = request.body
                for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw AgentError("The provider sent no answer.") }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte); if body.count > 8_000 { break } }
                        throw AgentError(Self.message(status: http.statusCode, body: body))
                    }
                    // `AsyncBytes.lines` drops empty lines, which end an event, so lines are cut here.
                    var line = Data()
                    for try await byte in bytes {
                        if byte == 0x0A {
                            continuation.yield(String(decoding: line.last == 0x0D ? line.dropLast() : line[...], as: UTF8.self))
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(byte)
                        }
                    }
                    if !line.isEmpty { continuation.yield(String(decoding: line, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The provider's message from its error JSON, or the status.
    static func message(status: Int, body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? [String: Any], let text = error["message"] as? String { return text }
        switch status {
        case 401: return "The provider rejected the API key."
        case 429: return "The provider is rate limiting this key. Try again in a minute."
        default: return "The provider answered with status \(status)."
        }
    }
}

/// Fetches a page as text. A redirect to an address `WebFetchTool` would refuse is not followed.
final class URLSessionWebFetcher: NSObject, WebFetching, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("IronPet iPhone agent", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw AgentError("The page answered with an error.") }
        let text = String(decoding: data.prefix(400_000), as: UTF8.self)
        return Self.plainText(text)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(WebFetchTool.allows) == true ? request : nil)
    }

    /// Drops scripts, styles and tags, and folds whitespace.
    static func plainText(_ html: String) -> String {
        var text = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<[^>]+>"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The phone's calendar and reminders through EventKit. The permission prompt appears the first time a tool needs the access, and a refusal
/// is the tool's answer, so the model can tell the user where to turn it on.
final class EventKitCalendar: DeviceCalendarHost, @unchecked Sendable {
    private let store = EKEventStore()

    func events(from start: Date, to end: Date) async throws -> [CalendarEntry] {
        guard try await store.requestFullAccessToEvents() else { throw AgentError("Calendar access is off. Turn it on for IronPet in Settings, Privacy, Calendars.") }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.prefix(40).map {
            CalendarEntry(title: $0.title ?? "Untitled", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay, location: $0.location)
        }
    }

    func addReminder(title: String, due: Date?) async throws {
        guard try await store.requestFullAccessToReminders() else { throw AgentError("Reminders access is off. Turn it on for IronPet in Settings, Privacy, Reminders.") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due { reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due) }
        try store.save(reminder, commit: true)
    }
}

/// The queue of items the agent added, in one JSON file in the app's own storage and out of backups.
final class FileInboxQueueStore: InboxQueueStoring, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(url: URL = FileInboxQueueStore.defaultURL) { self.url = url }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("phone-agent-inbox.json")
    }

    func load() -> [QueuedInboxItem] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([QueuedInboxItem].self, from: data)) ?? []
    }

    func save(_ items: [QueuedInboxItem]) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = url
        try? excluded.setResourceValues(values)
    }
}
