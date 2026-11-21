import Foundation

/// The current time and the time zone. Named `WallClock` because `Clock` is a Swift standard library protocol.
package protocol WallClock: Sendable {
    var isSupported: Bool { get }
    var now: Date { get throws }
    var timeZone: TimeZone { get throws }
}

extension WallClock {
    package var isSupported: Bool { true }
}

package struct SystemClock: WallClock {
    package init() {}

    package var now: Date { Date() }
    package var timeZone: TimeZone { TimeZone.current }
}

package struct UnsupportedClock: WallClock {
    package init() {}

    package var platform = PlatformName.current
    package var isSupported: Bool { false }
    package var now: Date { get throws { throw CapabilityError.unsupported(capability: "WallClock", platform: platform) } }
    package var timeZone: TimeZone { get throws { throw CapabilityError.unsupported(capability: "WallClock", platform: platform) } }
}
