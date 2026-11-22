import Foundation

/// The one error every `IronPetAPI` call throws. A client branches on `code` and shows `message`.
/// Both are plain strings on the wire, so a later network transport can send the error unchanged.
package struct APIError: Error, Codable, Equatable, LocalizedError {
    package init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    package enum Code: String, Codable, CaseIterable {
        /// The id in the request names nothing.
        case notFound = "not_found"
        /// A field is missing, out of range or not allowed.
        case invalid
        /// The request is valid but the current state refuses it, such as closing a task that is closed.
        case conflict
        /// The part of the app that serves the call is off, missing a permission or not running.
        case unavailable
        /// No connected client advertises the capability the call needs, such as a screenshot when only a phone is connected.
        case unsupported
        /// Anything else, with the cause in `message`.
        case failed
    }

    package let code: Code
    package let message: String

    package var errorDescription: String? { message }

    package static func notFound(_ message: String) -> APIError { APIError(code: .notFound, message: message) }
    package static func invalid(_ message: String) -> APIError { APIError(code: .invalid, message: message) }
    package static func conflict(_ message: String) -> APIError { APIError(code: .conflict, message: message) }
    package static func unavailable(_ message: String) -> APIError { APIError(code: .unavailable, message: message) }
    package static func unsupported(_ message: String) -> APIError { APIError(code: .unsupported, message: message) }
    package static func failed(_ message: String) -> APIError { APIError(code: .failed, message: message) }

    /// Wraps any error a store throws. An `APIError` passes through unchanged.
    package static func wrap(_ error: Error) -> APIError {
        if let error = error as? APIError { return error }
        if error is CapabilityError { return APIError(code: .unsupported, message: error.localizedDescription) }
        return APIError(code: .failed, message: error.localizedDescription)
    }
}
