import Foundation

package struct BriefRequest: Codable, Equatable {
    package init(kind: Brief.Kind, weekdays: [String]? = nil, day: Date? = nil) {
        self.kind = kind
        self.weekdays = weekdays
        self.day = day
    }

    package var kind: Brief.Kind
    /// The weekdays the brief runs on, so Monday's brief reaches back to Friday's meetings.
    package var weekdays: [String]?
    /// The recap's day. Nil is today.
    package var day: Date?
}

/// The morning brief and the day's recap, built from agent sessions, alerts and meetings.
@MainActor
package final class TodayAPI {
    private let source: BriefSource

    package init(sessions: SessionStore, signals: SignalStore, meetingsRoot: URL = Paths.meetings) {
        source = BriefSource(sessions: sessions, signals: signals, meetingsRoot: meetingsRoot)
    }

    /// Wraps a source built elsewhere, for previews and tests.
    package init(source: BriefSource) { self.source = source }

    /// What happened today, from the activity log. Without it the recap's agent turns come from the sessions still held.
    package var activity: BriefActivitySource? {
        get { source.activity }
        set { source.activity = newValue }
    }
    package var now: () -> Date {
        get { source.now }
        set { source.now = newValue }
    }
    package var calendar: Calendar {
        get { source.calendar }
        set { source.calendar = newValue }
    }

    /// Fires when anything a brief reads may have changed, before it changes.
    package var changes: ChangeSignal { source.changes }

    package func brief(_ request: BriefRequest) -> Brief { source.build(request.kind, weekdays: request.weekdays, day: request.day) }
}
