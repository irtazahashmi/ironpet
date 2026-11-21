import Foundation

/// The current time and the time zone. Named `WallClock` because `Clock` is a Swift standard library protocol.
protocol WallClock: Sendable {
    var isSupported: Bool { get }
    var now: Date { get throws }
    var timeZone: TimeZone { get throws }
}

extension WallClock {
    var isSupported: Bool { true }
}

struct SystemClock: WallClock {
    var now: Date { Date() }
    var timeZone: TimeZone { TimeZone.current }
}

struct UnsupportedClock: WallClock {
    var platform = PlatformName.current
    var isSupported: Bool { false }
    var now: Date { get throws { throw CapabilityError.unsupported(capability: "WallClock", platform: platform) } }
    var timeZone: TimeZone { get throws { throw CapabilityError.unsupported(capability: "WallClock", platform: platform) } }
}
