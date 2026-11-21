import Foundation

/// How a process ended: its exit code, or the signal that killed it.
package enum ProcessExit: Equatable, Sendable {
    case code(Int32)
    case signal(Int32)

    /// The exit code, or the signal number, like `Process.terminationStatus`.
    package var status: Int32 {
        switch self {
        case .code(let code): return code
        case .signal(let signal): return signal
        }
    }
}

/// What to start. The pipes the spec asks for are on the `RunningProcess`.
package struct ProcessSpec: Equatable, Sendable {
    package init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        directory: String? = nil,
        input: Input = .null,
        output: Output = .pipe,
        error: ErrorOutput = .pipe,
        ownProcessGroup: Bool = true
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.input = input
        self.output = output
        self.error = error
        self.ownProcessGroup = ownProcessGroup
    }

    package enum Input: Sendable { case null, pipe }
    package enum Output: Sendable { case null, pipe }
    package enum ErrorOutput: Sendable { case null, pipe, mergedIntoOutput }

    package var executable: String
    /// Everything after the program name.
    package var arguments: [String] = []
    /// The full environment, or nil to inherit the app's.
    package var environment: [String: String]?
    package var directory: String?
    package var input: Input = .null
    package var output: Output = .pipe
    package var error: ErrorOutput = .pipe
    /// Starts the process as the leader of a new process group, so `terminate` and `signalGroup` reach its children too, as
    /// `Process.terminate` always did.
    package var ownProcessGroup = true

    /// `/bin/sh -c command`.
    package static func shell(_ command: String, environment: [String: String]? = nil) -> ProcessSpec {
        ProcessSpec(executable: "/bin/sh", arguments: ["-c", command], environment: environment)
    }
}

/// A started process.
package protocol RunningProcess: AnyObject, Sendable {
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
    package var isRunning: Bool { exit == nil }
    /// The exit code, or the signal number when a signal ended the process. Zero while it runs.
    package var terminationStatus: Int32 { exit?.status ?? 0 }
}

/// Starts processes. The POSIX adapter is in core code, so every platform with `posix_spawn` has one.
package protocol ProcessSpawner: Sendable {
    var isSupported: Bool { get }
    /// Starts the process. Throws when it cannot start, for example when the executable is missing.
    func spawn(_ spec: ProcessSpec) throws -> RunningProcess
    /// Starts `command` in the platform's shell: `/bin/sh -c` on POSIX.
    func shell(command: String, environment: [String: String]?) throws -> RunningProcess
}

extension ProcessSpawner {
    package var isSupported: Bool { true }
}

package struct UnsupportedProcessSpawner: ProcessSpawner {
    package init() {}

    package var platform = PlatformName.current
    package var isSupported: Bool { false }
    private var error: CapabilityError { .unsupported(capability: "ProcessSpawner", platform: platform) }
    package func spawn(_ spec: ProcessSpec) throws -> RunningProcess { throw error }
    package func shell(command: String, environment: [String: String]?) throws -> RunningProcess { throw error }
}
