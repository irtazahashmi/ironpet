import SwiftUI
import UIKit
import WebKit

// Mermaid diagrams in the chat, drawn the way the Mac's `MermaidBlock` draws them: the bundled `mermaid.html` and `mermaid.min.js`
// run in a WKWebView, one per diagram, sized to the diagram. The page loads nothing from the network, runs Mermaid with
// `securityLevel: 'strict'` and refuses every navigation that is not the bundled file.

/// One diagram's web view and what it reported. The store keeps it, so a row that scrolls away and back reuses the picture.
@MainActor
final class MermaidHost: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    enum State: Equatable { case loading, shown, failed }

    @Published private(set) var state = State.loading
    @Published private(set) var height: CGFloat = 80
    let webView: WKWebView
    private let code: String
    private let dark: Bool
    private weak var store: MermaidStore?

    init(code: String, dark: Bool, page: URL, store: MermaidStore) {
        self.code = code
        self.dark = dark
        self.store = store
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.configuration.userContentController.add(WeakHandler(self), name: "size")
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // The page is as tall as the diagram, so only a diagram wider than the screen scrolls, and only sideways.
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        webView.accessibilityIdentifier = "mermaid-diagram"
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    /// True while a row shows this web view. A web view has one parent, so a second row with the same diagram gets its own host.
    var inUse: Bool { webView.superview != nil }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let source = (try? String(data: JSONEncoder().encode(code), encoding: .utf8)) ?? "\"\""
        store?.renderCount += 1
        webView.evaluateJavaScript("void renderDiagram(\(source), \(dark), true)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { state = .failed }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { state = .failed }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.isFileURL == true && action.navigationType == .other ? .allow : .cancel)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        // A diagram Mermaid cannot parse leaves the page with an error text. The phone shows the source instead.
        if (body["ok"] as? Bool) == false { state = .failed; return }
        guard let h = (body["h"] as? NSNumber)?.doubleValue, h > 0 else { return }
        height = CGFloat(h)
        state = .shown
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle with the host.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Keeps the most recent diagrams rendered. The transcript is lazy, so a row leaves the screen when it scrolls away and is built
/// again when it comes back. Without this, every diagram would run Mermaid again each time.
@MainActor
final class MermaidStore {
    static let shared = MermaidStore()
    /// How many times Mermaid ran. Tests read it to check that scrolling does not render again.
    var renderCount = 0
    private let page: URL?
    private let capacity: Int
    private var hosts: [(key: String, host: MermaidHost)] = []

    init(page: URL? = Bundle.main.url(forResource: "mermaid", withExtension: "html"), capacity: Int = 16) {
        self.page = page
        self.capacity = capacity
    }

    /// False in a build that could not download Mermaid: the caller shows the source.
    var isAvailable: Bool { page != nil }

    /// Nil when the app has no bundled Mermaid (a build that could not download it): the caller shows the source.
    func host(code: String, dark: Bool) -> MermaidHost? {
        guard let page else { return nil }
        let key = (dark ? "dark\n" : "light\n") + code
        if let index = hosts.firstIndex(where: { $0.key == key && !$0.host.inUse }) {
            let entry = hosts.remove(at: index)
            hosts.append(entry)
            return entry.host
        }
        let host = MermaidHost(code: code, dark: dark, page: page, store: self)
        hosts.append((key, host))
        if hosts.count > capacity, let old = hosts.firstIndex(where: { !$0.host.inUse }) { hosts.remove(at: old) }
        return host
    }
}

/// A closed ```mermaid block. It falls back to the source as a code block when Mermaid is not bundled or cannot draw the diagram.
struct MermaidBlock<Fallback: View>: View {
    let code: String
    @ViewBuilder let fallback: () -> Fallback
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if MermaidStore.shared.isAvailable {
            Diagram(code: code, dark: colorScheme == .dark, fallback: fallback)
        } else {
            fallback()
        }
    }

    private struct Diagram: View {
        // A StateObject asks the store once per row. Asking on every body pass would find the host busy and build another.
        @StateObject private var host: MermaidHost
        let fallback: () -> Fallback

        init(code: String, dark: Bool, fallback: @escaping () -> Fallback) {
            _host = StateObject(wrappedValue: MermaidStore.shared.host(code: code, dark: dark)!)
            self.fallback = fallback
        }

        var body: some View {
            if host.state == .failed {
                fallback()
            } else {
                MermaidWebView(host: host)
                    .frame(height: host.height)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("mermaid-block")
            }
        }
    }
}

private struct MermaidWebView: UIViewRepresentable {
    let host: MermaidHost
    func makeUIView(context: Context) -> WKWebView { host.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
