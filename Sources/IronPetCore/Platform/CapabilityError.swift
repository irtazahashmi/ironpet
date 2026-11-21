import Foundation

/// What an `Unsupported` adapter throws or returns. It names the capability and the platform that lacks it, so a client can
/// tell "this machine cannot do that" from a failure.
package enum CapabilityError: Error, Equatable, LocalizedError {
    case unsupported(capability: String, platform: String)

    package var errorDescription: String? {
        switch self {
        case .unsupported(let capability, let platform): return "\(capability) is not available on \(platform)"
        }
    }
}

/// The platform name `Unsupported` adapters report when nothing more specific is known.
package enum PlatformName {
    package static var current: String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #elseif os(Linux)
        return "Linux"
        #elseif os(Windows)
        return "Windows"
        #else
        return "this platform"
        #endif
    }
}
