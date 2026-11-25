import UIKit
import XCTest
@testable import IronPetRemote

@MainActor
final class MermaidTests: XCTestCase {
    /// Mermaid measures text, which needs the web view on screen, as it is in a chat row.
    private var window: UIWindow?
    private var attached: [MermaidHost] = []

    /// XCTest keeps a test case alive until the whole run ends, so a window with live web views would keep Mermaid and its web process
    /// running while the next suites execute. Blank the pages and drop the window here.
    override func tearDown() {
        for host in attached {
            host.webView.stopLoading()
            host.webView.loadHTMLString("", baseURL: nil)
            host.webView.removeFromSuperview()
        }
        attached = []
        window?.isHidden = true
        window = nil
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        super.tearDown()
    }

    private func wait(for host: MermaidHost, _ states: Set<MermaidHost.State>, timeout: TimeInterval = 20) {
        if host.webView.superview == nil {
            let window = self.window ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
            self.window = window
            window.isHidden = false
            host.webView.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
            window.addSubview(host.webView)
        }
        if !attached.contains(where: { $0 === host }) { attached.append(host) }
        let deadline = Date().addingTimeInterval(timeout)
        while !states.contains(host.state), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(states.contains(host.state), "state is \(host.state)")
    }

    private var page: URL? { Bundle.main.url(forResource: "mermaid", withExtension: "html") }

    // S4
    func testTheAppBundlesMermaidAndLoadsNothingFromTheNetwork() throws {
        let page = try XCTUnwrap(page, "mermaid.html is in the app bundle")
        XCTAssertNotNil(Bundle.main.url(forResource: "mermaid.min", withExtension: "js"), "mermaid.min.js is in the app bundle")
        let html = try String(contentsOf: page, encoding: .utf8)
        XCTAssertTrue(html.contains("default-src 'none'"), "the page's policy blocks every load it does not allow")
        XCTAssertFalse(html.contains("http://") || html.contains("https://"), "the page names no remote address")
        XCTAssertTrue(html.contains("<script src=\"mermaid.min.js\">"))
    }

    // S1
    func testAValidDiagramRendersAndGetsItsNaturalHeight() throws {
        let store = MermaidStore()
        let host = try XCTUnwrap(store.host(code: "graph TD\nA-->B\nB-->C", dark: false))
        wait(for: host, [.shown])
        XCTAssertGreaterThan(host.height, 80, "the web view is as tall as the drawn diagram")
        XCTAssertEqual(store.renderCount, 1)
    }

    // S2
    func testAnInvalidDiagramFallsBackToItsSource() throws {
        let host = try XCTUnwrap(MermaidStore().host(code: "this is not mermaid ((", dark: false))
        wait(for: host, [.failed])
    }

    func testWithoutBundledMermaidThereIsNoHostSoTheSourceShows() {
        XCTAssertNil(MermaidStore(page: nil).host(code: "graph TD\nA-->B", dark: false))
    }

    // S3
    func testScrollingBackToADiagramDoesNotRenderItAgain() throws {
        let store = MermaidStore()
        let first = try XCTUnwrap(store.host(code: "graph TD\nA-->B", dark: false))
        wait(for: first, [.shown])
        // The row scrolls off, which removes its web view, and a new one is built for the same diagram.
        first.webView.removeFromSuperview()
        let again = try XCTUnwrap(store.host(code: "graph TD\nA-->B", dark: false))
        XCTAssertTrue(first === again)
        XCTAssertEqual(store.renderCount, 1)
        // Dark mode is a different picture, so it renders once more.
        let dark = try XCTUnwrap(store.host(code: "graph TD\nA-->B", dark: true))
        XCTAssertFalse(first === dark)
        wait(for: dark, [.shown])
        XCTAssertEqual(store.renderCount, 2)
    }

    func testTheStoreForgetsTheOldestDiagramsPastItsCapacity() throws {
        let store = MermaidStore(capacity: 2)
        let a = try XCTUnwrap(store.host(code: "graph TD\nA-->B", dark: false))
        _ = store.host(code: "graph TD\nB-->C", dark: false)
        _ = store.host(code: "graph TD\nC-->D", dark: false)
        XCTAssertFalse(a === store.host(code: "graph TD\nA-->B", dark: false))
    }
}
