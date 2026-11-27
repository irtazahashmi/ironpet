import Foundation

/// One GUI process per ironpet root, held with an advisory `flock` on a file under the root. The kernel drops the lock when the
/// process exits or dies, so a crash or an update that kills the app never leaves a stale lock. The file holds the owner's pid.
package final class SingleInstance {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    package enum Outcome {
        /// This process owns the lock. Keep the value alive for the life of the process.
        case acquired(SingleInstance)
        /// Another process holds it, with the pid it wrote (nil if unreadable).
        case running(pid: Int32?)
    }

    package static func acquire(at url: URL) -> Outcome {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        // If the file can't be opened, start anyway: a broken guard must not stop the app from running.
        guard fd >= 0 else { return .acquired(SingleInstance(descriptor: -1)) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            ftruncate(fd, 0)
            let text = "\(getpid())\n"
            _ = text.withCString { pwrite(fd, $0, strlen($0), 0) }
            return .acquired(SingleInstance(descriptor: fd))
        }
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(fd, &buffer, buffer.count, 0)
        close(fd)
        let pid = count > 0 ? Int32(String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        return .running(pid: pid)
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}
