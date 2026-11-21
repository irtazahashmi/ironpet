import Foundation

/// How a process ended: its exit code, or the signal that killed it.
enum ProcessExit: Equatable, Sendable {
    case code(Int32)
    case signal(Int32)

    /// The exit code, or the signal number, like `Process.terminationStatus`.
    var status: Int32 {
        switch self {
        case .code(let code): return code
        case .signal(let signal): return signal
        }
    }
}

/// What to start. The pipes the spec asks for are on the `RunningProcess`.
struct ProcessSpec: Equatable, Sendable {
    enum Input: Sendable { case null, pipe }
    enum Output: Sendable { case null, pipe }
    enum ErrorOutput: Sendable { case null, pipe, mergedIntoOutput }

    var executable: String
    /// Everything after the program name.
    var arguments: [String] = []
    /// The full environment, or nil to inherit the app's.
    var environment: [String: String]?
    var directory: String?
    var input: Input = .null
    var output: Output = .pipe
    var error: ErrorOutput = .pipe
    /// Starts the process as the leader of a new process group, so `terminate` and `signalGroup` reach its children too, as
    /// `Process.terminate` always did.
    var ownProcessGroup = true

    /// `/bin/sh -c command`.
    static func shell(_ command: String, environment: [String: String]? = nil) -> ProcessSpec {
        ProcessSpec(executable: "/bin/sh", arguments: ["-c", command], environment: environment)
    }
}

/// A started process.
protocol RunningProcess: AnyObject, Sendable {
    var pid: Int32 { get }
    /// The write end of the process's stdin, when the spec asked for a pipe. `close()` it to send end of file.
    var input: FileHandle? { get }
    var output: FileHandle? { get }
    var error: FileHandle? { get }
    /// Nil while the process runs.
    var exit: ProcessExit? { get }
    /// Calls `handler` once, on a background queue, when the process has been reaped. Calls it right away when it already was.
    func whenExited(_ handler: @escaping @Sendable (ProcessExit) -> Void)
    /// SIGTERM to the process, and to its group when it leads one.
    func terminate()
    /// Sends `signal` to the process's group. Needs `ProcessSpec.ownProcessGroup`.
    func signalGroup(_ signal: Int32)
    /// Blocks until the process has been reaped.
    func waitUntilExit()
}

extension RunningProcess {
    var isRunning: Bool { exit == nil }
    /// The exit code, or the signal number when a signal ended the process. Zero while it runs.
    var terminationStatus: Int32 { exit?.status ?? 0 }
}

/// Starts processes. The POSIX adapter is in core code, so every platform with `posix_spawn` has one.
protocol ProcessSpawner: Sendable {
    var isSupported: Bool { get }
    /// Starts the process. Throws when it cannot start, for example when the executable is missing.
    func spawn(_ spec: ProcessSpec) throws -> RunningProcess
    /// Starts `command` in the platform's shell: `/bin/sh -c` on POSIX.
    func shell(command: String, environment: [String: String]?) throws -> RunningProcess
}

extension ProcessSpawner {
    var isSupported: Bool { true }
}

struct UnsupportedProcessSpawner: ProcessSpawner {
    var platform = PlatformName.current
    var isSupported: Bool { false }
    private var error: CapabilityError { .unsupported(capability: "ProcessSpawner", platform: platform) }
    func spawn(_ spec: ProcessSpec) throws -> RunningProcess { throw error }
    func shell(command: String, environment: [String: String]?) throws -> RunningProcess { throw error }
}
