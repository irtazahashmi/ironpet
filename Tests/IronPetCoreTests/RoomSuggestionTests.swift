import XCTest
@testable import IronPetCore

private struct FakeCalendar: CalendarEventSource {
    var all: [CalendarEvent]
    func events(from: Date, to: Date) -> [CalendarEvent] { all.filter { $0.start >= from && $0.start <= to } }
}

@MainActor
final class RoomSuggestionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String = "e1", title: String = "Planning", location: String? = "Room 4", url: String? = nil,
                       notes: String? = nil, in seconds: TimeInterval = 120, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: title, location: location, url: url, notes: notes,
                      start: t0.addingTimeInterval(seconds), isAllDay: allDay)
    }

    private struct Harness {
        var suggester: RoomSuggester
        var shown: Box
        final class Box { var events: [CalendarEvent] = []; var withdrawn = 0; var enabled = true; var busy = false; var now = Date() }
    }

    private func make(_ events: [CalendarEvent]) -> (RoomSuggester, Harness.Box) {
        let box = Harness.Box()
        box.now = t0
        let suggester = RoomSuggester(source: FakeCalendar(all: events), isEnabled: { box.enabled }, isBusy: { box.busy }, now: { box.now })
        suggester.show = { box.events.append($0) }
        suggester.withdraw = { box.withdrawn += 1 }
        return (suggester, box)
    }

    // S1
    func testRoomEventInsideWindowIsSuggestedOnce() {
        let (suggester, box) = make([event()])
        suggester.poll()
        suggester.poll()
        XCTAssertEqual(box.events.map(\.title), ["Planning"])
    }

    func testWindowBounds() {
        XCTAssertFalse(RoomEvents.inWindow(event(in: 301), now: t0))
        XCTAssertTrue(RoomEvents.inWindow(event(in: 300), now: t0))
        XCTAssertTrue(RoomEvents.inWindow(event(in: -300), now: t0))
        XCTAssertFalse(RoomEvents.inWindow(event(in: -301), now: t0))
        XCTAssertEqual(RoomEvents.windowBefore, 300)
        XCTAssertEqual(RoomEvents.windowAfter, 300)
    }

    func testEventOutsideWindowIsNotSuggested() {
        let (suggester, box) = make([event(in: 3600), event("old", in: -3600)])
        suggester.poll()
        XCTAssertTrue(box.events.isEmpty)
    }

    func testOnlyOneSuggestionAtATime() {
        let (suggester, box) = make([event("a", title: "A", in: 200), event("b", title: "B", in: 100)])
        suggester.poll()
        suggester.poll()
        XCTAssertEqual(box.events.map(\.title), ["B"])
    }

    // S3
    func testCallLinksInLocationUrlOrNotesMeanNoSuggestion() {
        let links = [
            "https://us02web.zoom.us/j/123456", "https://teams.microsoft.com/l/meetup-join/abc", "https://meet.google.com/abc-defg-hij",
            "https://acme.webex.com/meet/jo", "https://whereby.com/acme", "https://MEET.JIT.SI/Standup", "https://chime.aws/123",
        ]
        for link in links {
            XCTAssertFalse(RoomEvents.isRoomEvent(event(location: link)), link)
            XCTAssertFalse(RoomEvents.isRoomEvent(event(url: link)), link)
            XCTAssertFalse(RoomEvents.isRoomEvent(event(notes: "Join here: \(link) see you")), link)
            XCTAssertFalse(RoomEvents.isRoomEvent(event(location: "Room 4", notes: link)), link)
        }
        XCTAssertTrue(RoomEvents.isRoomEvent(event(location: "Room 4", notes: "Bring the slides")))
    }

    // S4
    func testNoLocationMeansNoSuggestion() {
        XCTAssertFalse(RoomEvents.isRoomEvent(event(location: nil)))
        XCTAssertFalse(RoomEvents.isRoomEvent(event(location: "   ")))
        XCTAssertFalse(RoomEvents.isRoomEvent(event(allDay: true)))
        let (suggester, box) = make([event(location: nil)])
        suggester.poll()
        XCTAssertTrue(box.events.isEmpty)
    }

    // S5
    func testDismissedOrIgnoredEventIsNotSuggestedAgain() {
        let (suggester, box) = make([event()])
        suggester.poll()
        suggester.dismissed(box.events[0])
        box.now = t0.addingTimeInterval(60)
        suggester.poll()
        XCTAssertEqual(box.events.count, 1)

        let (other, otherBox) = make([event("x")])
        other.poll()
        otherBox.now = t0.addingTimeInterval(500)
        other.poll()
        otherBox.now = t0.addingTimeInterval(10)
        other.poll()
        XCTAssertEqual(otherBox.events.count, 1, "ignoring it is not a reason to ask again")
        XCTAssertEqual(otherBox.withdrawn, 1, "the bubble is taken down when the window closes")
    }

    func testNextOccurrenceOfARecurringEventIsSuggestedAgain() {
        let first = event("r", in: 100)
        var second = first
        second.start = first.start.addingTimeInterval(7 * 86_400)
        let (suggester, box) = make([first, second])
        suggester.poll()
        box.now = second.start.addingTimeInterval(-60)
        suggester.poll()
        XCTAssertEqual(box.events.count, 1, "the earlier suggestion is still current until its window ends")
        box.now = second.start.addingTimeInterval(-60)
        suggester.dismissed(first)
        suggester.poll()
        XCTAssertEqual(box.events.count, 2)
    }

    // S6
    func testBusyMeansNoSuggestionAndWithdrawsOneShown() {
        let (suggester, box) = make([event()])
        box.busy = true
        suggester.poll()
        XCTAssertTrue(box.events.isEmpty)
        box.busy = false
        suggester.poll()
        XCTAssertEqual(box.events.count, 1)
        box.busy = true
        suggester.poll()
        XCTAssertEqual(box.withdrawn, 1)
    }

    func testDisabledMeansNoSuggestion() {
        let (suggester, box) = make([event()])
        box.enabled = false
        suggester.poll()
        XCTAssertTrue(box.events.isEmpty)
    }
}
