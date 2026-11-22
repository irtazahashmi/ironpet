import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A `ProcessSpawner` on `posix_spawn`. It starts every process with default signal handlers and an empty signal mask, and on
/// Darwin with nothing inherited but descriptors 0, 1 and 2.
package struct POSIXProcessSpawner: ProcessSpawner {
    package struct SpawnError: Error, LocalizedError {
        package init(message: String) {
            self.message = message
        }

        package let message: String
        package var errorDescription: String? { message }
    }

    package init() {}

    package func shell(command: String, environment: [String: String]?) throws -> RunningProcess {
        try spawn(.shell(command, environment: environment))
    }

    package func spawn(_ spec: ProcessSpec) throws -> RunningProcess {
        // Writing to a process that already exited raises SIGPIPE, which would end the app. The write fails with EPIPE instead.
        signal(SIGPIPE, SIG_IGN)
        var opened: [Int32] = []
        func closeAll() { opened.forEach { close($0) } }
        func makePipe() throws -> (read: Int32, write: Int32) {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else {
                closeAll()
                throw SpawnError(message: "cannot create a pipe: \(String(cString: strerror(errno)))")
            }
            opened += fds
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return (fds[0], fds[1])
        }

        let inPipe = spec.input == .pipe ? try makePipe() : nil
        let outPipe = spec.output == .pipe ? try makePipe() : nil
        let errPipe = spec.error == .pipe ? try makePipe() : nil

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let inPipe {
            posix_spawn_file_actions_adddup2(&actions, inPipe.read, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        if let outPipe {
            posix_spawn_file_actions_adddup2(&actions, outPipe.write, 1)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        }
        switch spec.error {
        case .pipe: posix_spawn_file_actions_adddup2(&actions, errPipe!.write, 2)
        case .null: posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        case .mergedIntoOutput:
            if let outPipe { posix_spawn_file_actions_adddup2(&actions, outPipe.write, 2) } else {
                posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
            }
        }
        if let directory = spec.directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }

        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults)
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &mask)
        var flags = Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK)
        if spec.ownProcessGroup {
            posix_spawnattr_setpgroup(&attr, 0)
            flags |= Int32(POSIX_SPAWN_SETPGROUP)
        }
        #if canImport(Darwin)
        // POSIX_SPAWN_CLOEXEC_DEFAULT: nothing is inherited but the descriptors the file actions set up. Darwin only.
        flags |= 0x4000
        #endif
        posix_spawnattr_setflags(&attr, Int16(flags))

        let environment = spec.environment ?? ProcessInfo.processInfo.environment
        var argv: [UnsafeMutablePointer<CChar>?] = ([spec.executable] + spec.arguments).map { strdup($0) }
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        argv.append(nil)
        envp.append(nil)
        defer { for pointer in argv + envp { free(pointer) } }

        var child: pid_t = 0
        let status = posix_spawn(&child, spec.executable, &actions, &attr, argv, envp)
        // The child has its own copies of the ends it uses. The parent keeps the other ends.
        if let inPipe { close(inPipe.read) }
        if let outPipe { close(outPipe.write) }
        if let errPipe { close(errPipe.write) }
        guard status == 0 else {
            if let inPipe { close(inPipe.write) }
            if let outPipe { close(outPipe.read) }
            if let errPipe { close(errPipe.read) }
            throw SpawnError(message: "cannot run \(spec.executable): \(String(cString: strerror(status)))")
        }
        return POSIXProcess(
            pid: child,
            input: inPipe.map { FileHandle(fileDescriptor: $0.write, closeOnDealloc: true) },
            output: outPipe.map { FileHandle(fileDescriptor: $0.read, closeOnDealloc: true) },
            error: errPipe.map { FileHandle(fileDescriptor: $0.read, closeOnDealloc: true) },
            leadsGroup: spec.ownProcessGroup)
    }
}

/// A process started by `POSIXProcessSpawner`. A dedicated thread reaps it with `waitpid`.
package final class POSIXProcess: RunningProcess, @unchecked Sendable { // `result` and `handlers` are read and written only under `lock`; the rest is `let`.
    package let pid: Int32
    package let input: FileHandle?
    package let output: FileHandle?
    package let error: FileHandle?

    private let lock = NSCondition()
    private var result: ProcessExit?
    private var handlers: [@Sendable (ProcessExit) -> Void] = []

    private let leadsGroup: Bool

    package init(pid: Int32, input: FileHandle?, output: FileHandle?, error: FileHandle?, leadsGroup: Bool) {
        self.leadsGroup = leadsGroup
        self.pid = pid
        self.input = input
        self.output = output
        self.error = error
        // A dedicated thread per child, not `DispatchQueue.global()`. A blocked `waitpid` would hold a shared worker for the child's
        // whole life, and a saturated pool would leave exited children unreaped.
        let reaper = Thread { [self] in
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0, errno == EINTR {}
            let exit: ProcessExit = (raw & 0x7f) == 0 ? .code((raw >> 8) & 0xff) : .signal(raw & 0x7f)
            lock.lock()
            result = exit
            let waiting = handlers
            handlers = []
            lock.broadcast()
            lock.unlock()
            for handler in waiting { handler(exit) }
        }
        reaper.name = "ironpet.reaper.\(pid)"
        reaper.stackSize = 128 * 1024
        reaper.start()
    }

    package var exit: ProcessExit? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    package func whenExited(_ handler: @escaping @Sendable (ProcessExit) -> Void) {
        lock.lock()
        if let result {
            lock.unlock()
            handler(result)
        } else {
            handlers.append(handler)
            lock.unlock()
        }
    }

    package func terminate() {
        guard exit == nil else { return }
        if leadsGroup { killpg(pid, SIGTERM) } else { kill(pid, SIGTERM) }
    }

    package func signalGroup(_ signal: Int32) {
        killpg(pid, signal)
    }

    package func waitUntilExit() {
        lock.lock()
        while result == nil { lock.wait() }
        lock.unlock()
    }
}
