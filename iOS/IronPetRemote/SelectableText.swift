import SwiftUI
import UIKit

// Text a reader can select across paragraphs and list items. SwiftUI's `Text` selects inside one view only, so a run of text blocks is
// drawn by one UITextView, and the edit menu of its selection gets "Ask about this".

private struct AskAboutSelectionKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    /// Called with the selected text when the reader chooses "Ask about this". Nil where a message cannot be replied to, which leaves
    /// the item out of the menu.
    var askAboutSelection: ((String) -> Void)? {
        get { self[AskAboutSelectionKey.self] }
        set { self[AskAboutSelectionKey.self] = newValue }
    }
}

private struct SelectingTextKey: EnvironmentKey {
    static let defaultValue: Binding<Bool>? = nil
}

extension EnvironmentValues {
    /// True while the reader is selecting the message's text, after choosing "Select text" in its menu. Nil where a message has no such item.
    var selectingText: Binding<Bool>? {
        get { self[SelectingTextKey.self] }
        set { self[SelectingTextKey.self] = newValue }
    }
}

/// One paragraph of a selectable run: a heading, a paragraph, a quote or a list item, with its inline markdown, links and Find highlights.
struct SelectablePiece {
    enum Marker: Equatable {
        case bullet(String)
        case number(String)
        case task(done: Bool)
    }

    enum Style: Equatable {
        case heading(size: CGFloat, bold: Bool)
        case body
        case quote
        case listItem(indent: Int, marker: Marker)
    }

    var text: AttributedString
    var style: Style
}

/// Builds the attributed string a UITextView shows for a run of pieces. The fonts, colours and spacing are the ones the SwiftUI blocks use.
enum SelectableTextBuilder {
    static let blockSpacing: CGFloat = 8
    static let itemSpacing: CGFloat = 4
    static let lineSpacing: CGFloat = 2

    static func attributed(_ pieces: [SelectablePiece], size: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, piece) in pieces.enumerated() {
            let next = index + 1 < pieces.count ? pieces[index + 1] : nil
            result.append(paragraph(piece, next: next, first: index == 0, size: size))
            if next != nil { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }

    private static func paragraph(_ piece: SelectablePiece, next: SelectablePiece?, first: Bool, size: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        var baseSize = size
        var weight = UIFont.Weight.regular
        var color = UIColor.label
        let out = NSMutableAttributedString()

        switch piece.style {
        case .heading(let headingSize, let bold):
            baseSize = headingSize
            weight = bold ? .bold : .semibold
            if !first { style.paragraphSpacingBefore = 2 }
        case .body:
            break
        case .quote:
            color = .secondaryLabel
        case .listItem(let indent, let marker):
            let lead = CGFloat(indent) * 14
            let (markerText, natural) = markerString(marker, size: size)
            // The marker sits right-aligned in a column of at least 10 pt (18 for a number), then 6 pt before the text, as the SwiftUI row did.
            let column: CGFloat = max(natural, { if case .number = marker { return 18 } else { return 10 } }())
            style.firstLineHeadIndent = lead
            style.headIndent = lead + column + 6
            style.tabStops = [NSTextTab(textAlignment: .right, location: lead + column), NSTextTab(textAlignment: .left, location: lead + column + 6)]
            style.defaultTabInterval = 0
            out.append(NSAttributedString(string: "\t"))
            out.append(markerText)
            out.append(NSAttributedString(string: "\t"))
        }

        if case .listItem = piece.style, case .listItem = next?.style { style.paragraphSpacing = itemSpacing - lineSpacing } else if next != nil { style.paragraphSpacing = blockSpacing - lineSpacing }

        let base = UIFont.systemFont(ofSize: baseSize, weight: weight)
        for run in piece.text.runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: font(for: run.inlinePresentationIntent, base: base), .foregroundColor: color]
            if let link = run.link { attributes[.link] = link }
            if run.inlinePresentationIntent?.contains(.strikethrough) == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if run.underlineStyle != nil { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if let foreground = run.foregroundColor { attributes[.foregroundColor] = UIColor(foreground) }
            if let background = run.backgroundColor { attributes[.backgroundColor] = UIColor(background) }
            out.append(NSAttributedString(string: String(piece.text[run.range].characters), attributes: attributes))
        }
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }

    private static func font(for intent: InlinePresentationIntent?, base: UIFont) -> UIFont {
        guard let intent else { return base }
        var traits = base.fontDescriptor.symbolicTraits
        if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
        if intent.contains(.emphasized) { traits.insert(.traitItalic) }
        var descriptor = base.fontDescriptor
        if intent.contains(.code) { descriptor = UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular).fontDescriptor }
        return UIFont(descriptor: descriptor.withSymbolicTraits(traits) ?? descriptor, size: base.pointSize)
    }

    /// The marker's text and its natural width. The line spacing is added below every line, so the first piece of a paragraph carries it too.
    private static func markerString(_ marker: SelectablePiece.Marker, size: CGFloat) -> (NSAttributedString, CGFloat) {
        let secondary = UIColor.secondaryLabel
        switch marker {
        case .bullet(let glyph):
            let string = NSAttributedString(string: glyph, attributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: secondary])
            return (string, string.size().width)
        case .number(let text):
            let string = NSAttributedString(string: text, attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: secondary])
            return (string, string.size().width)
        case .task(let done):
            let attachment = NSTextAttachment()
            let configuration = UIImage.SymbolConfiguration(pointSize: size)
            let image = UIImage(systemName: done ? "checkmark.square.fill" : "square", withConfiguration: configuration)?
                .withTintColor(secondary, renderingMode: .alwaysOriginal)
            attachment.image = image
            if let image { attachment.bounds = CGRect(x: 0, y: -(image.size.height - size) / 2 - size * 0.12, width: image.size.width, height: image.size.height) }
            return (NSAttributedString(attachment: attachment), image?.size.width ?? 0)
        }
    }

    /// The selection as text to quote: the list markers and checkboxes at the start of a line are not part of what the reader picked.
    static func quotable(_ selection: String) -> String {
        selection
            .replacingOccurrences(of: #"(?m)^\t(?:[•◦]|\d+[.)]|\x{FFFC})\t"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A text view whose text always wraps at its current width. SwiftUI sizes it with `sizeThatFits` at several widths, and a text container
/// left at an earlier width wraps differently from the frame the view ends up with.
final class WrappingTextView: UITextView {
    override func layoutSubviews() {
        if bounds.width > 0, textContainer.size.width != bounds.width - textContainerInset.left - textContainerInset.right {
            textContainer.size = CGSize(width: bounds.width - textContainerInset.left - textContainerInset.right, height: .greatestFiniteMagnitude)
        }
        super.layoutSubviews()
    }
}

/// A read-only text view that grows to its text and selects across all of it.
struct SelectableText: UIViewRepresentable {
    let pieces: [SelectablePiece]
    let size: CGFloat
    var accent: Color = .accentColor
    /// Whether this view takes the selection when the reader chooses "Select text". One view of a message does.
    var takesSelection = false
    @Environment(\.selectingText) private var selecting
    @Environment(\.openURL) private var openURL
    @Environment(\.askAboutSelection) private var ask

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = WrappingTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = false
        view.dataDetectorTypes = []
        // A reply reads as static text, as the SwiftUI Text it replaces did. Its label is its text.
        view.accessibilityTraits = .staticText
        view.delegate = context.coordinator
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A link has the tint and no underline, the way SwiftUI's Text draws it.
        view.linkTextAttributes = [:]
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.openURL = openURL
        context.coordinator.ask = ask
        context.coordinator.selecting = takesSelection ? selecting : nil
        view.tintColor = UIColor(accent)
        view.linkTextAttributes = [.foregroundColor: UIColor(accent)]
        let text = SelectableTextBuilder.attributed(pieces, size: size)
        // Assigning text clears the selection, so an update that changes nothing, such as a sibling block streaming, leaves it alone.
        guard !view.attributedText.isEqual(to: text) else { return }
        let selected = view.selectedRange
        view.attributedText = text
        if selected.length > 0, NSMaxRange(selected) <= text.length, view.isFirstResponder { view.selectedRange = selected }
        view.accessibilityLabel = text.string.replacingOccurrences(of: "\u{FFFC}", with: "")
        if takesSelection, selecting?.wrappedValue == true, !context.coordinator.active {
            context.coordinator.active = true
            DispatchQueue.main.async {
                view.becomeFirstResponder()
                view.selectedRange = NSRange(location: 0, length: view.attributedText.length)
                context.coordinator.presentMenu(in: view)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        if let width = proposal.width, width.isFinite {
            let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            return CGSize(width: width, height: ceil(fitted.height))
        }
        let fitted = uiView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        return CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIEditMenuInteractionDelegate {
        private var menuInteraction: UIEditMenuInteraction?
        private weak var menuView: UITextView?

        var openURL: OpenURLAction?
        var ask: ((String) -> Void)?
        var selecting: Binding<Bool>?
        var active = false

        /// Selecting mode ends when the reader taps away and the selection is gone.
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard active, textView.selectedRange.length == 0 else { return }
            active = false
            selecting?.wrappedValue = false
        }

        /// Shows the selection menu at once, since choosing Select text is the reader's request to act on the text.
        func presentMenu(in view: UITextView) {
            if menuInteraction == nil {
                let interaction = UIEditMenuInteraction(delegate: self)
                view.addInteraction(interaction)
                menuInteraction = interaction
            }
            menuView = view
            guard let range = view.selectedTextRange else { return }
            let rect = view.firstRect(for: range)
            let point = CGPoint(x: min(max(rect.midX, 40), max(view.bounds.width - 40, 40)), y: rect.minY)
            menuInteraction?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let view = menuView, view.selectedRange.length > 0 else { return nil }
            let copy = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak view] _ in
                guard let view else { return }
                UIPasteboard.general.string = (view.attributedText.string as NSString).substring(with: view.selectedRange)
            }
            return textView(view, editMenuForTextIn: view.selectedRange, suggestedActions: [copy])
        }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content, let openURL else { return defaultAction }
            return UIAction { _ in openURL(url) }
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let ask, range.length > 0 else { return UIMenu(children: suggestedActions) }
            let selected = (textView.attributedText.string as NSString).substring(with: range)
            let action = UIAction(title: "Ask about this", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak textView] _ in
                let quote = SelectableTextBuilder.quotable(selected)
                guard !quote.isEmpty else { return }
                textView?.selectedTextRange = nil
                ask(quote)
            }
            return UIMenu(children: [action] + suggestedActions)
        }
    }
}
