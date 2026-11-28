import EventKit
import Foundation
import IronPetCore

/// Reads the user's events through EventKit. It never asks for access: until the user turns the setting on and allows
/// it, `events` answers empty. Read only, and it keeps nothing.
struct EventKitCalendar: CalendarEventSource {
    private let store = EKEventStore()

    static var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Asks macOS for calendar access. Called only when the user turns the setting on.
    static func requestAccess() async -> Bool {
        if hasAccess { return true }
        return (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    func events(from: Date, to: Date) -> [CalendarEvent] {
        guard Self.hasAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEvent(id: event.eventIdentifier ?? event.calendarItemIdentifier, title: event.title ?? "",
                          location: event.location, url: event.url?.absoluteString, notes: event.notes,
                          start: event.startDate, isAllDay: event.isAllDay)
        }
    }
}
