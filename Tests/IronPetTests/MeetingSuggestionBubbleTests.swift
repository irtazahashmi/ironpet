import XCTest
@testable import IronPet
@testable import IronPetCore

@MainActor
final class MeetingSuggestionBubbleTests: XCTestCase {
    private func suggestion(_ origin: TaskSuggestion.Origin) -> TaskSuggestion {
        TaskSuggestion(id: "s1", title: "Send the notes", origin: origin, created: Date())
    }

    private let meeting = TaskSuggestion.Origin.meeting(URL(fileURLWithPath: "/tmp/meeting"))

    func testAMeetingBubbleFollowsItsSwitch() {
        var config = Config()
        XCTAssertTrue(AppDelegate.showsSuggestionBubble(for: [suggestion(meeting)], config: config))
        config.tasks.meetingSuggestionBubbles = false
        XCTAssertFalse(AppDelegate.showsSuggestionBubble(for: [suggestion(meeting)], config: config))
        config.tasks.meetingSuggestionBubbles = true
        XCTAssertTrue(AppDelegate.showsSuggestionBubble(for: [suggestion(meeting)], config: config), "turned back on")
    }

    func testAnAutomationSuggestionKeepsItsBubbleWhateverTheMeetingSwitchSays() {
        var config = Config()
        config.tasks.meetingSuggestionBubbles = false
        XCTAssertTrue(AppDelegate.showsSuggestionBubble(for: [suggestion(.automation(id: "a", name: "Watcher"))], config: config))
    }
}
