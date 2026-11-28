import Foundation

/// What an audio file must be to become a meeting, and the text of the refusal. The Mac's import and the phone's upload both use
/// these, so a file is refused with the same words on either.
public enum MeetingUploadLimits {
    public static let extensions = ["m4a", "mp3", "wav"]
    public static let maxBytes: Int64 = 1_073_741_824
    public static let maxSeconds: Double = 4 * 3600
    /// The size of one part the phone sends. The Mac accepts up to `RemoteUploads.maxBytes` per request.
    public static let partBytes = 4 << 20

    public static func unsupportedType(_ name: String) -> String { "ironpet imports m4a, mp3 and wav files. \(name) is not one of them." }
    public static func unreadable(_ name: String) -> String { "Could not read \(name)." }
    public static func tooLarge(_ name: String) -> String { "\(name) is larger than the 1 GB limit for an imported file." }
    public static func notAudio(_ name: String) -> String { "\(name) could not be read as audio." }
    public static func tooLong(_ name: String) -> String { "\(name) is longer than the 4 hour limit for an imported file." }

    /// The refusal for a file of this name and size, or nil when both are fine. The type is checked before the size, so a large
    /// file of the wrong kind is refused for its kind. The length needs the audio and is checked where the file can be decoded.
    public static func refusal(fileName: String, size: Int64?) -> String? {
        let name = (fileName as NSString).lastPathComponent
        guard extensions.contains((name as NSString).pathExtension.lowercased()) else { return unsupportedType(name) }
        guard let size else { return unreadable(name) }
        guard size <= maxBytes else { return tooLarge(name) }
        return nil
    }
}

/// `POST /v1/meeting-uploads` body: the phone names the upload so a repeated call after a lost answer finds the same one.
public struct RemoteUploadStart: Codable, Equatable, Sendable {
    public var id: String
    public var fileName: String
    public var size: Int64

    public init(id: String, fileName: String, size: Int64) { self.id = id; self.fileName = fileName; self.size = size }
}

/// How much of an upload the Mac holds. `received` is the offset of the next byte it wants.
public struct RemoteUploadStatus: Codable, Equatable, Sendable {
    public var id: String
    public var size: Int64
    public var received: Int64

    public init(id: String, size: Int64, received: Int64) { self.id = id; self.size = size; self.received = received }
}
