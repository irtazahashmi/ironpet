import IronPetKit
import UIKit
import XCTest

/// File paths in a reply are links. A tap asks the Mac for the file: its text if the path is inside the chat's folder, the Mac's reason if not.
final class ChatFileLinksUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer()
        try server.start()
        app = XCUIApplication()
    }

    override func tearDown() { server.stop() }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openChat() {
        server.chat.items = [
            RemoteChatItem(id: "m-1", kind: "user", date: Date(), text: "where does the login test fail?"),
            RemoteChatItem(id: "m-2", kind: "assistant", date: Date(),
                           text: "It fails in /Users/dev/demo-app/src/auth/login.ts:42, and the settings are in /etc/hosts. The chart is /Users/dev/demo-app/docs/diagram.png and the archive is /Users/dev/demo-app/blob.bin. A folder name like src/auth is not a path."),
        ]
        server.chat.state = "done"
        let size = CGSize(width: 240, height: 120)
        let png = UIGraphicsImageRenderer(size: size).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 20, y: 20, width: 80, height: 80))
        }
        server.setFilePreview(png, path: "/Users/dev/demo-app/docs/diagram.png", contentType: "image/png")
        server.setFilePreview(Data([0x50, 0x4B, 0, 3]), path: "/Users/dev/demo-app/blob.bin", contentType: "application/octet-stream")
        server.setFilePreview(Data("export function login(user: string) {\n  return refreshToken(user)\n}\n".utf8), path: "/Users/dev/demo-app/src/auth/login.ts")
        app.launchArguments = ["--reset-credentials"]
        app.launch()
        let field = app.textFields["pairing-link-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(server.pairingLink)
        app.buttons["pair-button"].tap()
        let tab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        XCTAssertTrue(app.textViews["chat-input"].waitForExistence(timeout: 20))
    }

    func testTappingAPathInAReplyShowsTheFileFromTheMac() {
        openChat()
        let link = app.links["/Users/dev/demo-app/src/auth/login.ts:42"]
        XCTAssertTrue(link.waitForExistence(timeout: 20), "the path is a link: \(app.debugDescription)")
        attach("file-1-reply-with-links")
        link.tap()
        let text = app.staticTexts["file-preview-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(text.label.contains("refreshToken(user)"), text.label)
        XCTAssertEqual(app.staticTexts["file-preview-path"].label, "/Users/dev/demo-app/src/auth/login.ts")
        XCTAssertEqual(server.previewRequests, ["/Users/dev/demo-app/src/auth/login.ts"], "the line number is not part of the path")
        attach("file-2-preview")
        app.buttons["file-preview-done"].tap()
        XCTAssertFalse(text.waitForExistence(timeout: 2))
    }

    func testAPathOutsideTheMacsFolderIsRefusedWithAClearMessage() {
        openChat()
        let link = app.links["/etc/hosts"]
        XCTAssertTrue(link.waitForExistence(timeout: 20))
        link.tap()
        let error = app.staticTexts["file-preview-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "The Mac only previews files inside the folders its chat works in")
        XCTAssertFalse(app.staticTexts["file-preview-text"].exists)
        attach("file-3-refused")
        app.buttons["file-preview-done"].tap()
    }

    func testTappingAnImagePathShowsTheImageAndABinaryFileSaysItIsNotShown() {
        openChat()
        let image = app.links["/Users/dev/demo-app/docs/diagram.png"]
        XCTAssertTrue(image.waitForExistence(timeout: 20))
        image.tap()
        XCTAssertTrue(app.images["file-preview-image"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["file-preview-text"].exists)
        attach("file-4-image-preview")
        app.buttons["file-preview-done"].tap()

        let binary = app.links["/Users/dev/demo-app/blob.bin"]
        XCTAssertTrue(binary.waitForExistence(timeout: 10))
        binary.tap()
        let error = app.staticTexts["file-preview-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "The phone previews text files and images only.")
        app.buttons["file-preview-done"].tap()
    }
}
