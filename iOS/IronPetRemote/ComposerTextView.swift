import SwiftUI
import UIKit

/// The message field. SwiftUI's `TextField` gives no hook for an image on the clipboard, so this wraps a `UITextView` that
/// catches the paste, keeps the draft in a binding and grows from one to five lines.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    /// Called on the main thread with the bytes of an image the user pasted.
    var onPasteImage: (Data) -> Void

    static let maxLines = 5

    func makeUIView(context: Context) -> PasteTextView {
        let view = PasteTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        view.isScrollEnabled = false
        view.autocorrectionType = .default
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "chat-input"
        view.accessibilityLabel = "Message"
        view.onPasteImage = onPasteImage
        return view
    }

    func updateUIView(_ view: PasteTextView, context: Context) {
        context.coordinator.parent = self
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
        let scrolls = content > maximum
        if view.isScrollEnabled != scrolls { DispatchQueue.main.async { view.isScrollEnabled = scrolls } }
        return CGSize(width: width, height: min(max(content, minimum), maximum))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
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
        if pasteText { super.paste(sender) }
    }
}
