import Foundation

/// A point in screen coordinates: points, origin at the top-left of the main display, y growing down. Accessibility positions and
/// mouse events use the same space, so a position read from an element can be clicked as it is. A display left of or above the main
/// one has negative values, and a Retina display needs no scaling because both sides count points, not pixels.
package struct DesktopPoint: Equatable {
    package var x: Double
    package var y: Double
    package init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// An element's or window's frame in screen points (AXPosition plus AXSize).
package struct DesktopRect: Equatable {
    package var x: Double
    package var y: Double
    package var width: Double
    package var height: Double
    package init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    package var center: DesktopPoint { DesktopPoint(x: x + width / 2, y: y + height / 2) }

    package func contains(_ point: DesktopPoint) -> Bool {
        point.x >= x && point.x < x + width && point.y >= y && point.y < y + height
    }

    /// The screen point for a point given relative to this frame's top-left corner.
    package func screenPoint(x relativeX: Double, y relativeY: Double) -> DesktopPoint {
        DesktopPoint(x: x + relativeX, y: y + relativeY)
    }
}

package enum DesktopMouseButton: String {
    case left, right
}

/// One mouse event the Mac adapter posts to an app's process.
package struct DesktopMouseEvent: Equatable {
    package enum Phase: String { case move, down, up }

    package var phase: Phase
    package var button: DesktopMouseButton
    /// 1 for a single click. A double click is two down and up pairs, the second with 2.
    package var clickState: Int
    package var flags: DesktopKeyFlags
    package var point: DesktopPoint

    package init(phase: Phase, button: DesktopMouseButton, clickState: Int, flags: DesktopKeyFlags, point: DesktopPoint) {
        self.phase = phase
        self.button = button
        self.clickState = clickState
        self.flags = flags
        self.point = point
    }
}

package enum DesktopScrollDirection: String, CaseIterable {
    case up, down, left, right
}

/// What posting a mouse event did.
package enum DesktopMouseOutcome: Equatable {
    case failed
    /// `cursorMoved` is true when the events went through the system-wide stream, so the real pointer moved.
    case posted(cursorMoved: Bool)
}

/// Parsing and building of the mouse tools' input, free of any Mac framework.
package enum DesktopMouse {
    package static let defaultScrollLines = 3
    package static let maxScrollLines = 20

    package struct InputError: Error, Equatable {
        package var message: String
        package init(_ message: String) { self.message = message }
    }

    /// "left" or "right". Nil means left.
    package static func parseButton(_ raw: String?) -> Result<DesktopMouseButton, InputError> {
        guard let raw else { return .success(.left) }
        guard let button = DesktopMouseButton(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) else {
            return .failure(InputError("\"\(raw)\" is not a button. Use left or right."))
        }
        return .success(button)
    }

    /// 1 or 2. Nil means 1.
    package static func parseCount(_ raw: Int?) -> Result<Int, InputError> {
        guard let raw else { return .success(1) }
        guard raw == 1 || raw == 2 else { return .failure(InputError("count is \(raw). Use 1 for a click or 2 for a double click.")) }
        return .success(raw)
    }

    /// Modifier names as an array or as one string joined by "+" or ",", such as "cmd+shift". The names are the ones `desktop_key` takes.
    package static func parseModifiers(_ raw: Any?) -> Result<(flags: DesktopKeyFlags, names: [String]), InputError> {
        var names: [String] = []
        if let list = raw as? [String] {
            names = list
        } else if let text = raw as? String {
            names = text.split(whereSeparator: { $0 == "+" || $0 == "," }).map(String.init)
        } else if raw != nil {
            return .failure(InputError("modifiers is a list such as [\"cmd\", \"shift\"], or text such as \"cmd+shift\"."))
        }
        switch DesktopKeys.parseModifiers(names) {
        case .success(let value): return .success(value)
        case .failure(let error): return .failure(InputError(error.message))
        }
    }

    package static func parseDirection(_ raw: String?) -> Result<DesktopScrollDirection, InputError> {
        guard let raw else { return .failure(InputError("direction is required: up, down, left or right.")) }
        guard let direction = DesktopScrollDirection(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) else {
            return .failure(InputError("\"\(raw)\" is not a direction. Use up, down, left or right."))
        }
        return .success(direction)
    }

    /// Lines to scroll, kept between 1 and the cap.
    package static func scrollLines(_ raw: Int?) -> Int {
        max(1, min(raw ?? defaultScrollLines, maxScrollLines))
    }

    /// The events of one click: the pointer moves there, then each down and up pair of the click count.
    package static func events(button: DesktopMouseButton, count: Int, flags: DesktopKeyFlags, at point: DesktopPoint) -> [DesktopMouseEvent] {
        var list = [DesktopMouseEvent(phase: .move, button: button, clickState: 0, flags: flags, point: point)]
        for state in 1...max(1, count) {
            list.append(DesktopMouseEvent(phase: .down, button: button, clickState: state, flags: flags, point: point))
            list.append(DesktopMouseEvent(phase: .up, button: button, clickState: state, flags: flags, point: point))
        }
        return list
    }

    /// How the log and the approval name a click: "click", "double click", "right click", "cmd+shift+click".
    package static func label(button: DesktopMouseButton, count: Int, modifiers: [String]) -> String {
        let kind = (count == 2 ? "double " : "") + (button == .right ? "right " : "") + "click"
        return modifiers.isEmpty ? kind : modifiers.joined(separator: "+") + "+" + kind
    }
}
