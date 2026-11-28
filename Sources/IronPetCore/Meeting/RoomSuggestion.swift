import Foundation

/// One calendar event, as much of it as room suggestions need.
package struct CalendarEvent: Equatable {
    package var id: String
    package var title: String
    package var location: String?
    package var url: String?
    package var notes: String?
    package var start: Date
    package var isAllDay: Bool

    package init(id: String, title: String, location: String? = nil, url: String? = nil, notes: String? = nil,
                 start: Date, isAllDay: Bool = false) {
        self.id = id
        self.title = title
        self.location = location
        self.url = url
        self.notes = notes
        self.start = start
        self.isAllDay = isAllDay
    }

    /// A recurring event keeps its identifier, so the start time tells one occurrence from the next.
    package var key: String { "\(id)|\(Int(start.timeIntervalSince1970))" }
}

/// Reads the user's calendar. The Mac adapter uses EventKit and answers empty until the user has allowed access.
package protocol CalendarEventSource {
    func events(from: Date, to: Date) -> [CalendarEvent]
}

/// Tells a call link from a plain place name.
package enum CallLinks {
    /// Hosts of the call providers ironpet knows. A link to any of them, in the location, URL or notes, means the
    /// meeting is a call and not a room.
    package static let hosts = [
        "zoom.us", "zoomgov.com", "zoom.com", "teams.microsoft.com", "teams.live.com", "meet.google.com",
        "hangouts.google.com", "webex.com", "whereby.com", "gotomeeting.com", "gotomeet.me", "goto.com",
        "bluejeans.com", "chime.aws", "meet.jit.si", "facetime.apple.com", "skype.com", "join.skype.com",
        "around.co", "slack.com/huddle", "discord.gg", "discord.com/channels", "meet.lync.com", "ringcentral.com",
        "dialpad.com", "livestorm.co", "pexip.me", "whatsapp.com/call",
    ]

    package static func contains(_ text: String?) -> Bool {
        guard let lowered = text?.lowercased(), !lowered.isEmpty else { return false }
        return hosts.contains { lowered.contains($0) }
    }
}

package enum RoomEvents {
    /// How long before the start the suggestion may appear, and how long after the start it stays possible.
    package static let windowBefore: TimeInterval = 5 * 60
    package static let windowAfter: TimeInterval = 5 * 60

    /// A timed event with a location and no call link anywhere in it.
    package static func isRoomEvent(_ event: CalendarEvent) -> Bool {
        guard !event.isAllDay else { return false }
        guard let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty else { return false }
        return ![event.location, event.url, event.notes].contains { CallLinks.contains($0) }
    }

    package static func inWindow(_ event: CalendarEvent, now: Date) -> Bool {
        now >= event.start.addingTimeInterval(-windowBefore) && now <= event.start.addingTimeInterval(windowAfter)
    }
}

/// Decides when Ghost suggests recording a room meeting from the calendar. It never records: the user's press does.
@MainActor
package final class RoomSuggester {
    /// The "Suggest recording room meetings" setting is on and so are meetings.
    package var isEnabled: () -> Bool
    /// A meeting is already being set up, recorded or wrapped up.
    package var isBusy: () -> Bool
    package var source: CalendarEventSource
    package var now: () -> Date
    /// Shows the suggestion. The user's press calls `accepted`, or `dismissed` for Not now.
    package var show: (CalendarEvent) -> Void = { _ in }
    /// Takes the suggestion down when it no longer applies.
    package var withdraw: () -> Void = {}

    /// Events already suggested once. An event is never suggested twice, whether the user pressed, dismissed or ignored it.
    package private(set) var offered: Set<String> = []
    package private(set) var current: CalendarEvent?

    package init(source: CalendarEventSource, isEnabled: @escaping () -> Bool, isBusy: @escaping () -> Bool,
                 now: @escaping () -> Date = Date.init) {
        self.source = source
        self.isEnabled = isEnabled
        self.isBusy = isBusy
        self.now = now
    }

    /// One look at the calendar. Shows at most one suggestion, and takes it down once it stops applying.
    package func poll() {
        let time = now()
        if let shown = current {
            if !isEnabled() || isBusy() || time > shown.start.addingTimeInterval(RoomEvents.windowAfter) { clear() }
            return
        }
        guard isEnabled(), !isBusy() else { return }
        let events = source.events(from: time.addingTimeInterval(-RoomEvents.windowAfter),
                                   to: time.addingTimeInterval(RoomEvents.windowBefore))
        guard let next = events.filter({ RoomEvents.isRoomEvent($0) && RoomEvents.inWindow($0, now: time) && !offered.contains($0.key) })
            .min(by: { $0.start < $1.start }) else { return }
        offered.insert(next.key)
        current = next
        show(next)
    }

    package func accepted(_ event: CalendarEvent) {
        if current?.key == event.key { current = nil }
    }

    package func dismissed(_ event: CalendarEvent) {
        if current?.key == event.key { current = nil }
    }

    private func clear() {
        current = nil
        withdraw()
    }
}
