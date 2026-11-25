import AppKit
import ApplicationServices
import Carbon

/// What has keyboard focus in the frontmost app when a transcript is ready.
enum DictationFocus {
    /// A text field that takes text.
    case field(DictationField)
    /// A password field. It never gets text.
    case secure
    /// Nothing that takes text has focus.
    case none
    /// ironpet is not allowed to read other apps' fields.
    case noAccess
}

/// A focused text field in another app.
protocol DictationField {
    /// Puts `text` at the cursor through Accessibility. False when the app did not take it.
    func insert(_ text: String) -> Bool
    /// The field's frame in screen coordinates with a bottom-left origin, to place the recording bar next to it.
    var frame: CGRect? { get }
}

protocol DictationFocusReader {
    func current() -> DictationFocus
}

/// What happened to a transcript.
enum DictationOutcome: Equatable {
    /// Accessibility put the text at the cursor.
    case inserted
    /// The app refused Accessibility, so the text was pasted and the earlier clipboard came back.
    case pasted
    /// The text was left on the clipboard because there was nowhere safe to put it.
    case copied(Reason)

    enum Reason: Equatable {
        case secureField
        case noField
        case noAccess
        /// The paste keystroke could not be sent.
        case pasteBlocked
    }
}

/// Puts a transcript into the focused text field: Accessibility first, then a paste that gives the clipboard back.
/// It never targets a secure field, and when no text field can take the text it leaves it on the clipboard.
@MainActor
struct DictationDelivery {
    var focus: DictationFocusReader
    var board: NSPasteboard
    /// Sends Cmd-V to the frontmost app. False when macOS did not allow it.
    var sendPaste: () -> Bool
    /// Waits for the app to read the pasteboard before the old contents are put back.
    var settle: () async -> Void = { try? await Task.sleep(for: .milliseconds(300)) }

    func deliver(_ text: String) async -> DictationOutcome {
        switch focus.current() {
        case .secure: return copy(text, because: .secureField)
        case .none: return copy(text, because: .noField)
        case .noAccess: return copy(text, because: .noAccess)
        case .field(let field):
            if field.insert(text) { return .inserted }
            return await paste(text)
        }
    }

    private func copy(_ text: String, because reason: DictationOutcome.Reason) -> DictationOutcome {
        board.clearContents()
        board.setString(text, forType: .string)
        return .copied(reason)
    }

    /// Replaces the clipboard with the text, pastes, and restores the earlier contents unless something else wrote to
    /// the clipboard in the meantime.
    private func paste(_ text: String) async -> DictationOutcome {
        let saved = PasteboardSnapshot(board)
        board.clearContents()
        board.setString(text, forType: .string)
        let ours = board.changeCount
        guard sendPaste() else { return .copied(.pasteBlocked) }
        await settle()
        if board.changeCount == ours { saved.restore(to: board) }
        return .pasted
    }
}

/// Everything on a pasteboard, so it can be put back byte for byte.
struct PasteboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ board: NSPasteboard) {
        items = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func restore(to board: NSPasteboard) {
        board.clearContents()
        let restored = items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
    }
}

// MARK: - Accessibility

/// Reads the focused element of the frontmost app.
struct AXFocusReader: DictationFocusReader {
    func current() -> DictationFocus {
        guard AXIsProcessTrusted() else { return .noAccess }
        var value: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        // These calls run on the main thread, so a hung app must not hold it for the 6 s default.
        AXUIElementSetMessagingTimeout(system, 0.5)
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .none }
        return Self.classify(value as! AXUIElement)
    }

    static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
    static let secureSubrole = "AXSecureTextField"

    static func classify(_ element: AXUIElement) -> DictationFocus {
        let role = string(element, kAXRoleAttribute)
        if string(element, kAXSubroleAttribute) == secureSubrole { return .secure }
        let takesText = role.map(textRoles.contains) == true || settable(element, kAXSelectedTextAttribute)
        return takesText ? .field(AXField(element: element)) : .none
    }

    fileprivate static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    fileprivate static func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var flag = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &flag) == .success && flag.boolValue
    }
}

struct AXField: DictationField {
    let element: AXUIElement

    /// Sets the selected text, which inserts at the cursor and replaces a selection. Some apps report success and
    /// change nothing, so when the value can be read the insertion counts only if it changed.
    func insert(_ text: String) -> Bool {
        guard AXFocusReader.settable(element, kAXSelectedTextAttribute) else { return false }
        let before = AXFocusReader.string(element, kAXValueAttribute)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { return false }
        guard let before, let after = AXFocusReader.string(element, kAXValueAttribute) else { return true }
        return after != before
    }

    var frame: CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              let primary = NSScreen.screens.first else { return nil }
        // Accessibility measures from the top left of the primary screen, AppKit from the bottom left.
        return CGRect(x: origin.x, y: primary.frame.height - origin.y - extent.height, width: extent.width, height: extent.height)
    }
}

/// Posts Cmd-V to the frontmost app.
enum PasteKeystroke {
    static func send() -> Bool {
        guard AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
