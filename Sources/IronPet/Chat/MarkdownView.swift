import AppKit
import IronPetCore
import IronPetKit
import SwiftUI
import WebKit

extension ChatMarkdown {
    /// The inline markdown of `text` with file paths and record ids made into links.
    static func inlineWithPathLinks(_ text: String) -> AttributedString { RecordLinks.link(FilePathLinks.link(inline(text))) }
}

/// Renders a reply's markdown as SwiftUI views. Each run of text blocks (headings, paragraphs, lists, quotes)
/// is one selectable text view, so a drag selects across them. Code, tables, diagrams and rules are views of
/// their own and selection stops at them. `size` is the reply's base font size.
struct MarkdownView: View {
    let text: String
    var size: CGFloat = 13.5
    /// Highlights for the open find bar. Nil for rows with no match.
    var find: ChatFind.RowHighlight?
    /// Redraws when a background check finds that a path in the text exists, so it turns into a link.
    @ObservedObject private var paths = PathCache.shared

    private enum Piece {
        case text([ChatMarkdown.Block], segment: Int)
        case block(ChatMarkdown.Block, segment: Int)
    }

    var body: some View {
        let blocks = ChatMarkdown.parse(text)
        // Only a row with a match needs the segment numbers, so streaming without find parses nothing extra.
        let starts = find == nil ? [] : blocks.reduce(into: [0]) { $0.append($0.last! + ChatMarkdown.segments(of: $1).count) }
        let pieces = Self.pieces(blocks, starts: starts)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .text(let blocks, let segment):
                    MarkdownTextView(content: MarkdownText.attributed(blocks, size: size, firstSegment: segment, find: find))
                case .block(let block, let segment):
                    view(for: block, segment: segment)
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { FilePathLinks.handle($0) })
                }
            }
        }
    }

    private static func pieces(_ blocks: [ChatMarkdown.Block], starts: [Int]) -> [Piece] {
        var pieces: [Piece] = []
        for (index, block) in blocks.enumerated() {
            let segment = starts.isEmpty ? 0 : starts[index]
            if ChatMarkdown.isTextBlock(block) {
                if case .text(let run, let first)? = pieces.last {
                    pieces[pieces.count - 1] = .text(run + [block], segment: first)
                } else {
                    pieces.append(.text([block], segment: segment))
                }
            } else {
                pieces.append(.block(block, segment: segment))
            }
        }
        return pieces
    }

    @ViewBuilder
    private func view(for block: ChatMarkdown.Block, segment: Int) -> some View {
        switch block {
        case .code(let language, let text, _):
            if let diagram = ChatMarkdown.mermaidSource(of: block) {
                MermaidBlock(code: diagram)
            } else {
                CodeBlock(language: language, code: text, segment: segment, find: find)
            }
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows, segment: segment, find: find)
        case .rule:
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.vertical, 2)
        case .heading, .paragraph, .list, .quote:
            EmptyView()
        }
    }
}

private struct CodeBlock: View {
    let language: String?
    let code: String
    let segment: Int
    let find: ChatFind.RowHighlight?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? SharedSymbols.allow : SharedSymbols.copy)
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.borderless)
                .pointerCursor()
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                ChatFind.text(AttributedString(code), segment: segment, find: find)
                    .font(.system(size: 12, design: .monospaced))
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]
    let segment: Int
    let find: ChatFind.RowHighlight?
    @ObservedObject private var paths = PathCache.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        ChatFind.text(ChatMarkdown.inlineWithPathLinks(cell), segment: segment + column, find: find).fontWeight(.semibold)
                    }
                }
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).gridCellColumns(max(header.count, 1))
                let rowStarts = rows.reduce(into: [segment + header.count]) { $0.append($0.last! + $1.count) }
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            ChatFind.text(ChatMarkdown.inlineWithPathLinks(cell), segment: rowStarts[r] + column, find: find)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Mermaid

/// `mermaid.html` and `mermaid.min.js` are copied into the app bundle by `scripts/bundle.sh`. Debug builds
/// and preview renders don't have them, so diagrams fall back to their source as a code block.
enum MermaidAssets {
    static var page: URL? { Bundle.main.url(forResource: "mermaid", withExtension: "html") }
}

private struct MermaidBlock: View {
    let code: String
    @State private var height: CGFloat = 80
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let page = MermaidAssets.page {
            MermaidWebView(page: page, code: code, dark: colorScheme == .dark, height: $height)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        } else {
            CodeBlock(language: "mermaid", code: code, segment: 0, find: nil)
        }
    }
}

/// Renders one diagram with the bundled mermaid.js. Mermaid runs with `securityLevel: 'strict'` (no click
/// handlers or HTML in labels), the page loads nothing from the network, and any navigation away is refused.
private struct MermaidWebView: NSViewRepresentable {
    let page: URL
    let code: String
    let dark: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> PassThroughWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "size")
        let view = PassThroughWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.pending = (code, dark)
        view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: PassThroughWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.render(code, dark: dark, in: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        var pending: (code: String, dark: Bool)?
        private var loaded = false
        private var shown: (code: String, dark: Bool)?

        init(height: Binding<CGFloat>) { self.height = height }

        func render(_ code: String, dark: Bool, in view: WKWebView) {
            guard loaded else { pending = (code, dark); return }
            if let shown, shown.code == code, shown.dark == dark { return }
            shown = (code, dark)
            let source = (try? String(data: JSONEncoder().encode(code), encoding: .utf8)) ?? "\"\""
            view.evaluateJavaScript("void renderDiagram(\(source), \(dark))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let pending { render(pending.code, dark: pending.dark, in: webView) }
            pending = nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.isFileURL == true && action.navigationType == .other ? .allow : .cancel)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let size = message.body as? [String: Any], let h = (size["h"] as? NSNumber)?.doubleValue, h > 0 else { return }
            height.wrappedValue = CGFloat(h)
        }
    }
}

/// Scrolling over a diagram scrolls the chat, not the (non-scrolling) page.
private final class PassThroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

/// WKUserContentController retains its handlers; this breaks the cycle with the coordinator.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
