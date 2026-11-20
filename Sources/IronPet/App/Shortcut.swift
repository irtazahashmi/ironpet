import AppKit
import Carbon

/// A global shortcut written as `"cmd+opt+shift+g"`.
struct Shortcut: Equatable {
    var keyCode: Int
    /// Carbon modifier flags (`cmdKey`, `optionKey`, …).
    var modifiers: Int

    private static let modifierNames: [(names: [String], flag: Int, symbol: String, label: String)] = [
        (["ctrl", "control", "⌃"], controlKey, "⌃", "ctrl"),
        (["opt", "option", "alt", "⌥"], optionKey, "⌥", "opt"),
        (["shift", "⇧"], shiftKey, "⇧", "shift"),
        (["cmd", "command", "⌘"], cmdKey, "⌘", "cmd"),
    ]

    private static let keys: [(name: String, code: Int)] = {
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z),
            ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4),
            ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
            ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("[", kVK_ANSI_LeftBracket), ("]", kVK_ANSI_RightBracket),
            (";", kVK_ANSI_Semicolon), ("'", kVK_ANSI_Quote), (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period),
            ("/", kVK_ANSI_Slash), ("\\", kVK_ANSI_Backslash), ("`", kVK_ANSI_Grave),
            ("space", kVK_Space), ("return", kVK_Return), ("tab", kVK_Tab), ("escape", kVK_Escape),
            ("up", kVK_UpArrow), ("down", kVK_DownArrow), ("left", kVK_LeftArrow), ("right", kVK_RightArrow),
        ]
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11,
                     kVK_F12].enumerated().map { ("f\($0.offset + 1)", $0.element) }
        return letters + fkeys
    }()

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// nil for an empty string (shortcut off) or one that can't be parsed.
    init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, let key = Self.keys.first(where: { $0.name == keyName }) else { return nil }
        var flags = 0
        for part in parts.dropLast() {
            guard let modifier = Self.modifierNames.first(where: { $0.names.contains(part) }) else { return nil }
            flags |= modifier.flag
        }
        guard Self.isAllowed(keyName: keyName, modifiers: flags) else { return nil }
        self.init(keyCode: key.code, modifiers: flags)
    }

    /// From a key press while recording. nil for keys we can't name or presses without a modifier.
    init?(event: NSEvent) {
        guard let key = Self.keys.first(where: { $0.code == Int(event.keyCode) }) else { return nil }
        var flags = 0
        let mods = event.modifierFlags
        if mods.contains(.control) { flags |= controlKey }
        if mods.contains(.option) { flags |= optionKey }
        if mods.contains(.shift) { flags |= shiftKey }
        if mods.contains(.command) { flags |= cmdKey }
        guard Self.isAllowed(keyName: key.name, modifiers: flags) else { return nil }
        self.init(keyCode: key.code, modifiers: flags)
    }

    /// Function keys work alone; anything else needs ⌘, ⌥ or ⌃ so typing (including Shift for capitals) isn't
    /// hijacked.
    private static func isAllowed(keyName: String, modifiers: Int) -> Bool {
        let isFunctionKey = keyName.count > 1 && keyName.hasPrefix("f") && Int(keyName.dropFirst()) != nil
        return isFunctionKey || modifiers & (cmdKey | optionKey | controlKey) != 0
    }

    private var keyName: String { Self.keys.first { $0.code == keyCode }?.name ?? "?" }

    /// `"cmd+opt+g"`, the form stored in config.json.
    var text: String {
        (Self.modifierNames.filter { modifiers & $0.flag != 0 }.map(\.label) + [keyName]).joined(separator: "+")
    }

    /// `"⌥⌘G"`, for menus and labels.
    var display: String {
        let symbols: [String: String] = ["space": "Space", "return": "↩", "tab": "⇥", "escape": "⎋",
                                         "up": "↑", "down": "↓", "left": "←", "right": "→"]
        let key = symbols[keyName] ?? keyName.uppercased()
        return Self.modifierNames.filter { modifiers & $0.flag != 0 }.map(\.symbol).joined() + key
    }

    /// Display form of a config string, or nil when it's off or invalid.
    static func display(_ text: String) -> String? {
        Shortcut(text)?.display
    }
}
