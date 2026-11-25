import AppKit
import Combine
import IronPetCore
import SwiftUI

/// System-wide dictation: a global shortcut records in whatever app has focus, the chat's engine transcribes, and the
/// text goes to the focused text field. It owns a second `VoiceController` so the chat's own voice note state is never
/// touched, but the recording and transcription code is the same.
@MainActor
final class DictationController {
    let voice = VoiceController()
    var delivery: DictationDelivery
    /// A short notice: the title and a line below it.
    var onNotice: (String, String) -> Void = { _, _ in }
    /// False while the chat records a voice note, so the two never share the Enter and Esc keys.
    var canStart: () -> Bool = { true }
    private(set) var lastOutcome: DictationOutcome?
    private let bar = DictationBarPanel()
    private var subscription: AnyCancellable?
    private var delivering: Task<Void, Never>?

    init(delivery: DictationDelivery) {
        self.delivery = delivery
        voice.onTranscript = { [weak self] text in self?.deliver(text) }
        voice.onFailure = { [weak self] message, _ in
            self?.voice.discardRetryAudio()
            self?.onNotice("Dictation", message)
        }
        bar.attach(voice)
        subscription = voice.$phase.sink { [weak self] phase in
            guard let self else { return }
            if phase == .idle { bar.dismiss() } else { bar.present(near: self.delivery.focus.current().field?.frame) }
        }
    }

    /// The dictation shortcut to register: nil when voice notes are off or the shortcut is cleared.
    nonisolated static func hotkey(in config: Config) -> String? {
        guard config.voice.enabled, !config.hotkeys.dictation.isEmpty else { return nil }
        return config.hotkeys.dictation
    }

    /// The shortcut went down. A second press stops the recording and sends it.
    func shortcutPressed(_ kind: VoiceController.Source = .microphone) {
        if voice.isBusy {
            voice.shortcutPressed(kind)
        } else if canStart() {
            voice.start(kind)
        }
    }

    /// Settings turned voice notes off, or ironpet is quitting.
    func cancel() {
        delivering?.cancel()
        voice.cancel()
    }

    /// Puts a finished transcript where the user is typing, and says so when it went to the clipboard instead.
    func deliver(_ text: String) {
        delivering = Task { [weak self] in
            guard let self else { return }
            let outcome = await delivery.deliver(text)
            lastOutcome = outcome
            if let notice = Self.notice(for: outcome) { onNotice("Dictation", notice) }
        }
    }

    static func notice(for outcome: DictationOutcome) -> String? {
        switch outcome {
        case .inserted, .pasted: nil
        case .copied(.secureField): "That is a password field, so nothing was typed. The text is on your clipboard."
        case .copied(.noField): "No text field has focus. The text is on your clipboard."
        case .copied(.noAccess): "Allow ironpet under Privacy & Security → Accessibility to type into other apps. The text is on your clipboard."
        case .copied(.pasteBlocked): "That app did not take the text. It is on your clipboard."
        }
    }
}

extension DictationFocus {
    var field: DictationField? {
        if case .field(let field) = self { field } else { nil }
    }
}

/// The recording bar over other apps. It never takes focus, so the field being dictated into keeps the cursor.
final class DictationBarPanel: NSPanel {
    private static let size = DictationPill.size
    private var host: NSHostingController<DictationPill>?

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func attach(_ voice: VoiceController) {
        let host = NSHostingController(rootView: DictationPill(voice: voice))
        host.sizingOptions = []
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        contentViewController = host
        setContentSize(Self.size)
        self.host = host
    }

    /// Shows the bar above the focused field, below it when there is no room, or at the top of the screen under the
    /// mouse when the field's position is unknown.
    func present(near field: CGRect?) {
        guard !isVisible else { return }
        let screen = NSScreen.screens.first { field.map($0.frame.intersects) ?? NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        setFrame(CGRect(origin: Self.origin(for: field, in: area), size: Self.size), display: true)
        orderFrontRegardless()
    }

    func dismiss() { orderOut(nil) }

    static func origin(for field: CGRect?, in area: CGRect, size: CGSize = DictationBarPanel.size) -> CGPoint {
        var origin: CGPoint
        if let field {
            origin = CGPoint(x: field.midX - size.width / 2, y: field.maxY + 8)
            if origin.y + size.height > area.maxY { origin.y = field.minY - size.height - 8 }
        } else {
            origin = CGPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 12)
        }
        origin.x = min(max(origin.x, area.minX + 8), area.maxX - size.width - 8)
        origin.y = min(max(origin.y, area.minY + 8), area.maxY - size.height - 8)
        return origin
    }
}
