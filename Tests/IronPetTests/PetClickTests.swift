import AppKit
import XCTest
@testable import IronPet
@testable import IronPetCore

@MainActor
final class PetClickTests: XCTestCase {
    private let size = CGSize(width: 120, height: 120)

    private func makeView(badge: Int, mood: PetMood = .needsInput) -> (PetView, NSWindow) {
        let view = PetView(atlas: nil, size: size)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        view.show(mood, badge: badge)
        return (view, window)
    }

    private func release(on view: PetView, window: NSWindow, at point: CGPoint) {
        let event = NSEvent.mouseEvent(with: .leftMouseUp, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        view.mouseUp(with: event)
    }

    func testBadgeHitCoversTheDrawnCircleAndAFewPointsAround() {
        let bounds = CGRect(origin: .zero, size: size)
        let rect = PetView.badgeRect(in: bounds)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        XCTAssertTrue(PetView.badgeHit(center, in: bounds, badgeShown: true))
        XCTAssertTrue(PetView.badgeHit(CGPoint(x: rect.maxX - 1, y: center.y), in: bounds, badgeShown: true))
        XCTAssertTrue(PetView.badgeHit(CGPoint(x: rect.minX - 2, y: center.y), in: bounds, badgeShown: true))
        XCTAssertFalse(PetView.badgeHit(CGPoint(x: rect.minX - 12, y: center.y), in: bounds, badgeShown: true))
        XCTAssertFalse(PetView.badgeHit(CGPoint(x: bounds.midX, y: bounds.midY), in: bounds, badgeShown: true))
    }

    func testNoBadgeMeansNoBadgeHit() {
        let bounds = CGRect(origin: .zero, size: size)
        let rect = PetView.badgeRect(in: bounds)
        XCTAssertFalse(PetView.badgeHit(CGPoint(x: rect.midX, y: rect.midY), in: bounds, badgeShown: false))
    }

    func testClickOnTheBodyOpensChatEvenWithABadge() {
        let (view, window) = makeView(badge: 3)
        var body = 0, badge = 0
        view.onClick = { body += 1 }
        view.onBadgeClick = { badge += 1 }
        release(on: view, window: window, at: CGPoint(x: 40, y: 40))
        XCTAssertEqual(body, 1)
        XCTAssertEqual(badge, 0)
    }

    func testClickOnTheBadgeOpensWhatItCounts() {
        let (view, window) = makeView(badge: 3)
        var body = 0, badge = 0
        view.onClick = { body += 1 }
        view.onBadgeClick = { badge += 1 }
        let rect = PetView.badgeRect(in: view.bounds)
        release(on: view, window: window, at: CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(badge, 1)
        XCTAssertEqual(body, 0)
    }

    func testClickWithoutABadgeOpensChat() {
        let (view, window) = makeView(badge: 0)
        var body = 0, badge = 0
        view.onClick = { body += 1 }
        view.onBadgeClick = { badge += 1 }
        let rect = PetView.badgeRect(in: view.bounds)
        release(on: view, window: window, at: CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(body, 1)
        XCTAssertEqual(badge, 0)
    }
}

/// Which section a click on the pet opens, through `PetController`.
@MainActor
final class PetClickRoutingTests: XCTestCase {
    private func signal(_ id: String) -> Signal {
        Signal(id: id, title: "CI failed", subtitle: "", url: nil, label: "CI", symbol: "x", mood: .failed, ask: nil)
    }

    private func makePet(_ statuses: AgentStatus..., alerts: Int = 0) -> PetController {
        let store = SessionStore()
        store.loadPreview(statuses.enumerated().map { AgentSession(id: "\($0.offset)", source: .claude, status: $0.element) })
        let signals = SignalStore()
        for i in 0..<alerts { signals.add(signal("\(i)"), notify: false) }
        let pet = PetController(store: store, signals: signals)
        pet.onChatToggle = { [unowned pet] in pet.showWindow(.chat) }
        return pet
    }

    func testBodyClickOpensChatWhileAnAgentNeedsYou() {
        let pet = makePet(.needsInput, alerts: 2)
        pet.handleClick()
        XCTAssertEqual(pet.windowModel.section, .chat)
        pet.window.close()
    }

    func testBodyClickOpensChatWithNothingToAttendTo() {
        let pet = makePet()
        pet.handleClick()
        XCTAssertEqual(pet.windowModel.section, .chat)
        pet.window.close()
    }

    func testBadgeClickOpensAgentsWhenAnAgentNeedsYou() {
        let pet = makePet(.needsInput, alerts: 2)
        pet.handleBadgeClick()
        XCTAssertEqual(pet.windowModel.section, .agents)
        pet.window.close()
    }

    func testBadgeClickOpensAlertsWhenAlertsAreWhatItCounts() {
        let pet = makePet(.done, alerts: 1)
        pet.handleBadgeClick()
        XCTAssertEqual(pet.windowModel.section, .alerts)
        pet.window.close()
    }
}
