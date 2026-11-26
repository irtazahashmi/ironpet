import XCTest
@testable import IronPet

@MainActor
final class SidebarLayoutTests: XCTestCase {
    private let all = IronPetSection.shown(chat: true, transcripts: true, automations: true)

    private func defaults() -> UserDefaults {
        let name = "ironpet-sidebar-layout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testTheDefaultLayoutKeepsTodaysOrder() {
        XCTAssertEqual(SidebarLayout().visible(all), all)
    }

    // S1
    func testDraggingInboxAboveAgentsSurvivesARestart() {
        let store = defaults()
        let model = IronPetWindowModel(defaults: store)
        model.moveRow(.inbox, before: .agents, in: all)
        let expected: [IronPetSection] = [.chat, .inbox, .agents, .alerts, .notifications, .transcripts, .screen, .actions, .automations, .memory]
        XCTAssertEqual(model.sidebarRows(all), expected)
        XCTAssertEqual(IronPetWindowModel(defaults: store).sidebarRows(all), expected)
    }

    func testOnMoveOffsetsReorderTheVisibleRows() {
        var layout = SidebarLayout()
        layout.moveVisible(from: IndexSet(integer: 4), to: 1, in: all)
        XCTAssertEqual(layout.visible(all).prefix(3).map(\.self), [.chat, .inbox, .agents])
    }

    // S2
    func testHidingMemoryPersists() {
        let store = defaults()
        let model = IronPetWindowModel(defaults: store)
        model.setSectionHidden(.memory, true)
        XCTAssertFalse(model.sidebarRows(all).contains(.memory))
        XCTAssertFalse(IronPetWindowModel(defaults: store).sidebarRows(all).contains(.memory))
    }

    // S3
    func testShowingASectionAgainRestoresItsPlace() {
        var layout = SidebarLayout()
        layout.setHidden(.screen, true)
        layout.moveVisible(from: IndexSet(integer: 1), to: 3, in: all)
        layout.setHidden(.screen, false)
        let rows = layout.visible(all)
        XCTAssertEqual(rows.firstIndex(of: .screen), all.firstIndex(of: .screen))
        var plain = SidebarLayout()
        plain.setHidden(.memory, true)
        plain.setHidden(.memory, false)
        XCTAssertEqual(plain.visible(all), all)
    }

    // S4
    func testChatCannotBeHidden() {
        var layout = SidebarLayout(order: [], hidden: ["chat"])
        XCTAssertFalse(layout.isHidden(.chat))
        layout.setHidden(.chat, true)
        XCTAssertTrue(layout.visible(all).contains(.chat))
        let model = IronPetWindowModel(defaults: defaults())
        model.setSectionHidden(.chat, true)
        XCTAssertEqual(model.sidebarRows(all).first, .chat)
    }

    // S5
    func testShortcutsFollowTheVisibleRows() {
        var layout = SidebarLayout()
        layout.setHidden(.agents, true)
        let rows = layout.visible(all)
        XCTAssertEqual(IronPetSection.forShortcut("2", in: rows), .alerts)
        XCTAssertFalse((1...9).contains { IronPetSection.forShortcut("\($0)", in: rows) == .agents })
        XCTAssertNil(IronPetSection.agents.shortcutLabel(in: rows))
    }

    // S6
    func testANotificationOpensAHiddenSection() {
        let model = IronPetWindowModel(defaults: defaults())
        model.setSectionHidden(.notifications, true)
        model.openNotification("n1")
        XCTAssertEqual(model.section, .notifications)
        XCTAssertEqual(model.focusNotification, "n1")
        XCTAssertFalse(model.sidebarRows(all).contains(.notifications))
    }

    func testALinkToAHiddenInboxStillOpensIt() {
        let model = IronPetWindowModel(defaults: defaults())
        model.setSectionHidden(.inbox, true)
        model.section = .inbox
        XCTAssertEqual(model.section, .inbox)
        XCTAssertFalse(model.sidebarRows(all).contains(.inbox))
    }

    // S7
    func testTheTipShowsTheShortcutOfTheNewPosition() {
        var layout = SidebarLayout()
        layout.move(.inbox, before: .agents, in: all)
        let rows = layout.visible(all)
        XCTAssertEqual(IronPetSection.inbox.hint(in: rows), "Inbox (⌘2)")
        XCTAssertEqual(IronPetSection.agents.hint(in: rows), "Agents (⌘3)")
    }

    func testANewSectionIsAppendedAndAGoneIdIsDropped() {
        let layout = SidebarLayout(order: ["gone", "memory", "chat", "chat"], hidden: ["gone"])
        let rows = layout.visible(all)
        XCTAssertEqual(rows.first, .memory)
        XCTAssertEqual(Set(rows), Set(all))
        XCTAssertEqual(rows.count, all.count)
        XCTAssertEqual(rows.last, .automations)
    }

    func testMovingKeepsHiddenSectionsInTheirSlots() {
        var layout = SidebarLayout()
        layout.setHidden(.alerts, true)
        layout.move(.inbox, before: .agents, in: all)
        layout.setHidden(.alerts, false)
        XCTAssertEqual(layout.visible(all).prefix(5).map(\.self), [.chat, .inbox, .alerts, .agents, .notifications])
    }
}
