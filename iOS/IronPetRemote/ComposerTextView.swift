import SwiftUI
import UIKit

/// The message field. SwiftUI's `TextField` gives no hook for an image on the clipboard, so this wraps a `UITextView` that
/// catches the paste, keeps the draft in a binding and grows from one to five lines.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    /// Called on the main thread with the bytes of an image the user pasted.
    var onPasteImage: (Data) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    static let maxLines = 5
    /// Top and bottom text inset. One body line plus this makes the field as tall as the 36 pt side circles.
    static let verticalInset: CGFloat = 7

    func makeUIView(context: Context) -> PasteTextView {
        let view = PasteTextView()
        view.delegate = context.coordinator
        view.font = bodyFont
        view.adjustsFontForContentSizeCategory = false
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: Self.verticalInset, left: 6, bottom: Self.verticalInset, right: 6)
        // Always scrollable: turning it on after layout left a taller draft stuck at its top. The field's height is capped in sizeThatFits.
        view.isScrollEnabled = true
        view.alwaysBounceVertical = false
        view.autocorrectionType = .default
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "chat-input"
        view.accessibilityLabel = "Message"
        view.onPasteImage = onPasteImage
        return view
    }

    /// The body font at the size the chat uses, which the text size setting can raise above the system's.
    private var bodyFont: UIFont {
        .preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: typeSize.contentSizeCategory))
    }

    func updateUIView(_ view: PasteTextView, context: Context) {
        context.coordinator.parent = self
        if view.font?.pointSize != bodyFont.pointSize { view.font = bodyFont }
        view.onPasteImage = onPasteImage
        // Setting the text while an input method holds marked text would cancel the composition.
        if view.text != text, view.markedTextRange == nil { view.text = text }
        if isFocused, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    /// One line tall when empty, then as tall as the text up to five lines, after which the field scrolls.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PasteTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 280
        let inset = view.textContainerInset.top + view.textContainerInset.bottom
        let line = view.font?.lineHeight ?? 20
        let minimum = ceil(line + inset)
        let maximum = ceil(line * CGFloat(Self.maxLines) + inset)
        let content = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        if content > maximum { DispatchQueue.main.async { view.revealCaret() } }
        return CGSize(width: width, height: min(max(content, minimum), maximum))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? PasteTextView)?.revealCaret()
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.isFirstResponder { (textView as? PasteTextView)?.revealCaret() }
        }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.isFocused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.isFocused = false }
    }
}

/// A text view that offers Paste when the clipboard holds an image and routes that paste to `onPasteImage`.
final class PasteTextView: UITextView {
    var onPasteImage: ((Data) -> Void)?

    /// `hasImages` reports what the clipboard holds without reading it, so asking costs no permission prompt.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pasteText = ComposerPaste.handle(.general) { [weak self] data in self?.onPasteImage?(data) }
        if pasteText {
            super.paste(sender)
            revealCaret()
            // The field grows and starts scrolling after the paste lays out, so reveal once more then.
            DispatchQueue.main.async { [weak self] in self?.revealCaret() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.revealCaret() }
        }
    }

    private var lastSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        // A rotation changes the line breaks, and SwiftUI then changes the field's height a moment later.
        // Either leaves the caret outside the visible part, so reveal it after each size change.
        if bounds.size != lastSize {
            lastSize = bounds.size
            DispatchQueue.main.async { [weak self] in self?.revealCaret() }
        }
    }

    /// Scrolls so the caret and the text up to it are visible, including after the last line.
    func revealCaret() {
        guard isFirstResponder, let end = selectedTextRange?.end else { return }
        layoutIfNeeded()
        if selectedRange.location >= text.utf16.count {
            // At the end of the text, go to the exact bottom, which leaves the bottom inset below the last line.
            let bottom = contentSize.height - bounds.height + adjustedContentInset.bottom
            setContentOffset(CGPoint(x: contentOffset.x, y: max(-adjustedContentInset.top, bottom)), animated: false)
        } else {
            scrollRectToVisible(caretRect(for: end).insetBy(dx: 0, dy: -ComposerTextView.verticalInset), animated: false)
        }
    }
}
