import AppKit
import IronPetCore
import os

/// Reads the text selected in a transcript message. SwiftUI's selectable `Text` does not expose its selection, so the
/// probe sends the responder chain the same `copy:` that Cmd-C sends, reads what it put on the pasteboard, and puts the
/// user's earlier pasteboard contents back.
@MainActor
enum SelectionProbe {
    /// The selected text, or nil when nothing is selected or the selection is in a text field such as the composer.
    static func selectedText(keepOnPasteboard: Bool = false) -> String? {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor { return nil }
        // A transcript text view hands over its selection directly, so the read does not depend on `copy:` and the pasteboard.
        if let view = NSApp.keyWindow?.firstResponder as? ChatTextView { return selectedText(in: view) }
        let board = NSPasteboard.general
        let before = board.changeCount
        let saved = snapshot(board)
        guard NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil), board.changeCount != before else { return nil }
        let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keepOnPasteboard { restore(saved, to: board) }
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// The selection in a transcript text view as the pasteboard would get it, or nil when it is empty.
    static func selectedText(in view: ChatTextView) -> String? {
        guard let storage = view.textStorage else { return nil }
        let range = view.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
        let text = MarkdownText.plainText(of: storage, in: range).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Why the Ask button was not shown or was hidden. One line per reason goes to the log, never message content.
    enum Skip: String, Error {
        case noMessageID = "text view has no message id"
        case emptySelection = "selection is empty or only whitespace"
        case noWindow = "text view is not in a window"
        case scrolledOut = "end of the selection is scrolled out of view"
        case notKeyWindow = "mouse-up outside the key window"
        case noSelectionOwner = "no focused reply text view and no hovered message with a selection"
        case messageGone = "selected message is no longer in the transcript"
        case scrolling = "scroll wheel hides the button until the selection is re-read"
        case focusNotInReply = "focus left the reply text views"
    }

    private static let logger = Logger(subsystem: "com.ironpet", category: "ask-about-selection")

    /// Logs why the button is not shown. Read with
    /// `log stream --level debug --predicate 'subsystem == "com.ironpet" AND category == "ask-about-selection"'`.
    static func logSkip(_ reason: Skip, source: String) {
        logger.debug("skipped source=\(source, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
    }

    /// Where the Ask button goes for the selection in `view`: the message, and the end of the selection in window
    /// coordinates with a top-left origin. Fails with the reason when the view has no message, nothing is selected,
    /// or the end of the selection is scrolled out of view.
    static func resolveAnchor(for view: ChatTextView) -> Result<(id: UUID, point: CGPoint), Skip> {
        guard let id = view.messageID else { return .failure(.noMessageID) }
        guard selectedText(in: view) != nil else { return .failure(.emptySelection) }
        guard let window = view.window else { return .failure(.noWindow) }
        let range = view.selectedRange()
        let last = NSRange(location: NSMaxRange(range) - 1, length: 1)
        let screen = view.firstRect(forCharacterRange: last, actualRange: nil)
        let rect = window.convertFromScreen(screen)
        // A selection scrolled out of the transcript's visible area has no place for the button.
        guard view.visibleRect.intersects(view.convert(rect, from: nil)) else { return .failure(.scrolledOut) }
        let height = window.contentView?.bounds.height ?? 0
        return .success((id, CGPoint(x: rect.maxX, y: height - rect.minY)))
    }

    static func anchor(for view: ChatTextView) -> (id: UUID, point: CGPoint)? {
        try? resolveAnchor(for: view).get()
    }

    private static func snapshot(_ board: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]], to board: NSPasteboard) {
        board.clearContents()
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
}
