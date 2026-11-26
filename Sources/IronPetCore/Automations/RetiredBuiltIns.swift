import Foundation

/// The automations that earlier builds added to every install: the morning brief, the end-of-day recap, the mail and calendar
/// checks, and the GitHub and Sentry alerts. ironpet adds none of them now. This file only describes what they looked like, so an
/// upgrade can tell a copy the user never touched from one they turned on or edited.
package enum RetiredBuiltIns {
    package static let morningBriefID = "morning-brief"
    package static let dayRecapID = "day-recap"
    package static let mailCalendarID = "mail-calendar"
    package static let weekdays = AutomationDefaults.weekdays

    package static func morningBrief(enabled: Bool = false) -> Automation {
        Automation(id: morningBriefID, name: "Morning brief", enabled: enabled,
                   trigger: .init(type: "daily", times: ["09:00"], weekdays: weekdays, catchUpMinutes: 180),
                   action: .init(type: "digest", digest: "brief"), presentation: .init(symbol: "sun.max.fill"), createdBy: "user",
                   note: "Open alerts, meeting action items, inbox items and waiting agents. Built from data on this Mac; no agent runs.")
    }

    package static func dayRecap(enabled: Bool = false) -> Automation {
        Automation(id: dayRecapID, name: "End-of-day recap", enabled: enabled,
                   trigger: .init(type: "daily", times: ["18:00"], weekdays: weekdays, catchUpMinutes: 120),
                   action: .init(type: "digest", digest: "recap"), presentation: .init(symbol: "moon.stars.fill"), createdBy: "user",
                   note: "What agents finished, alerts resolved, meetings held and what is still open. Built from data on this Mac; no agent runs.")
    }

    package static func mailCalendar(enabled: Bool = false) -> Automation {
        Automation(id: mailCalendarID, name: "Mail and calendar checks", enabled: enabled,
                   trigger: .init(type: "interval", minutes: 60, clock: "wall"),
                   action: .init(type: "prompt", prompt: "{{prompt.\(mailCalendarID)}}", session: "own", report: "chat"),
                   presentation: .init(symbol: "envelope.badge"), createdBy: "user",
                   note: "Checks new mail and the next 48 hours of events each hour and adds items to the inbox. Needs a mail or calendar tool the agent can use. Its prompt is in Settings → Prompts.")
    }

    /// Every automation an earlier build added, switched off, as it shipped.
    package static var shipped: [Automation] {
        [morningBrief(), dayRecap(), mailCalendar(), AutomationDefaults.github(enabled: false), AutomationDefaults.sentry(enabled: false)]
    }

    /// True when `automation` is a shipped copy that the user never switched on or edited. Any difference, even in the note,
    /// makes it the user's own.
    package static func isUntouched(_ automation: Automation) -> Bool {
        shipped.contains { $0 == automation }
    }
}
