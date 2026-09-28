import Foundation
import Darwin

/// Runs a command-line tool attached to a pseudo-terminal.
///
/// Why a pty and not a pipe: libc line-buffers stdout only when it is a terminal,
/// so through a pipe Argyll's progress arrives in 4 KB bursts long after the fact.
/// And Argyll's "hit any key" prompts switch the terminal to raw mode to read one
/// byte, which needs stdin to be a tty in the first place.
public final class PTYProcess {
    public enum Failure: Error {
        case openpty(errno: Int32)
        case spawn(errno: Int32)
    }

    public let pid: pid_t
    /// Raw bytes from the child's stdout and stderr, merged as on a real terminal.
    public let output: AsyncStream<Data>

    private let master: Int32
    private let exitTask: Task<Int32, Never>

    public init(executable: String,
                arguments: [String],
                environment: [String: String] = [:],
                workingDirectory: String? = nil) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw Failure.openpty(errno: errno)
        }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, slave)
        posix_spawn_file_actions_addclose(&actions, master)
        if let dir = workingDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, dir)
        }

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // SETSID: the child gets its own session, so the pty becomes its terminal.
        // CLOEXEC_DEFAULT: nothing but fds 0/1/2 leaks into the child.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        for (key, value) in environment { env[key] = value }

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, executable, &actions, &attr, argv, envp)
        close(slave)
        guard rc == 0 else {
            close(master)
            throw Failure.spawn(errno: rc)
        }

        self.pid = pid
        self.master = master

        var continuation: AsyncStream<Data>.Continuation!
        self.output = AsyncStream { continuation = $0 }
        let cont = continuation!
        let fd = master
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n > 0 { cont.yield(Data(buffer[0..<n])); continue }
                if n < 0 && errno == EINTR { continue }
                break   // 0 or EIO: the child closed its side of the pty
            }
            close(fd)
            cont.finish()
        }

        self.exitTask = Task.detached {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            if (status & 0x7f) == 0 { return (status >> 8) & 0xff }   // WEXITSTATUS
            return 128 + (status & 0x7f)                               // killed by signal
        }
    }

    /// Writes raw bytes to the child's stdin.
    public func send(_ text: String) {
        _ = text.withCString { write(master, $0, strlen($0)) }
    }

    /// Answers an Argyll "hit any key to continue" prompt.
    public func pressAnyKey() { send("\r") }

    /// Escape is Argyll's own abort key; the tool cleans up and exits non-zero.
    public func sendEscape() { send("\u{1b}") }

    public func terminate() { kill(pid, SIGTERM) }

    /// Exit code, or 128 + signal number if the child was killed.
    public func waitUntilExit() async -> Int32 { await exitTask.value }
}
