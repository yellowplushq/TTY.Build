import CPedalsPTY
import Darwin
import Foundation

/// One shell process attached to a pseudo-terminal (PROTOCOL.md §6).
///
/// The child is spawned with `forkpty`, which creates a new session and makes
/// the slave device its controlling terminal before executing the shell.
/// Output and exit are delivered as callbacks on the queue passed to `init`.
public final class PTYProcess: @unchecked Sendable {
    public enum PTYError: Error, CustomStringConvertible {
        case openptyFailed(errno: Int32)
        case spawnFailed(errno: Int32)

        public var description: String {
            switch self {
            case .openptyFailed(let e): "openpty failed: \(String(cString: strerror(e)))"
            case .spawnFailed(let e): "posix_spawn failed: \(String(cString: strerror(e)))"
            }
        }
    }

    public let pid: pid_t
    /// Slave tty device path ("/dev/ttys003"). Identifies this PTY for
    /// coding-agent ownership matching (AgentMonitor): a hook whose reported
    /// tty equals `ttyPath` runs inside this session.
    public let ttyPath: String?
    private let masterFD: Int32
    private let queue: DispatchQueue
    private let readSource: DispatchSourceRead
    private let exitSource: DispatchSourceProcess
    private var closed = false

    /// Stdin the tty input queue would not accept yet (the child stopped
    /// reading). Flushed by `writeSource` when the master becomes writable.
    private var pendingStdin = Data()
    /// Only exists while `pendingStdin` is non-empty.
    private var writeSource: DispatchSourceWrite?
    private static let maxPendingStdin = 1 << 20 // 1 MiB

    /// Called on `queue` with each chunk of raw PTY output.
    public var onOutput: (@Sendable (Data) -> Void)?
    /// Called on `queue` exactly once when the child exits, with the exit code
    /// (or 128+signal when terminated by a signal).
    public var onExit: (@Sendable (Int32) -> Void)?

    public init(
        shell: String,
        arguments: [String],
        cwd: String,
        cols: UInt16,
        rows: UInt16,
        extraEnvironment: [String: String] = [:],
        queue: DispatchQueue
    ) throws {
        self.queue = queue

        var master: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"]?.isEmpty != false { environment["LANG"] = "en_US.UTF-8" }
        environment["SHELL"] = shell
        for (key, value) in extraEnvironment { environment[key] = value }
        // Pedals terminals advertise full color support. Do not let the
        // desktop app's own launch environment disable color in child tools.
        // Removing the key matters: many CLIs treat even an empty NO_COLOR as
        // an explicit request to suppress ANSI colors.
        environment.removeValue(forKey: "NO_COLOR")
        // zsh otherwise paints a reverse-video `%` whenever the preceding
        // output has no trailing newline. It is useful in a local terminal but
        // becomes visual noise after remote replay and resize redraws. Pedals
        // deliberately owns this value so callers cannot re-enable the mark.
        environment["PROMPT_EOL_MARK"] = ""

        var argv = ([shell] + arguments).map { strdup($0) } + [nil]
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var childErrno: Int32 = 0
        let childPid = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envpBuffer in
                shell.withCString { shellPointer in
                    cwd.withCString { cwdPointer in
                        pedals_forkpty_exec(
                            &master,
                            &size,
                            shellPointer,
                            argvBuffer.baseAddress,
                            envpBuffer.baseAddress,
                            cwdPointer,
                            &childErrno
                        )
                    }
                }
            }
        }
        guard childPid > 0 else {
            if master >= 0 { close(master) }
            throw PTYError.spawnFailed(errno: childErrno != 0 ? childErrno : errno)
        }

        pid = childPid
        masterFD = master
        // ptsname is safe here despite its static buffer: spawns are
        // serialized on the SessionManager queue.
        ttyPath = ptsname(master).map { String(cString: $0) }

        // The master stays O_NONBLOCK for its whole life: a blocking write
        // would stall the (shared) queue whenever the child stops reading
        // stdin. Overflow goes to `pendingStdin` instead.
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        exitSource = DispatchSource.makeProcessSource(
            identifier: childPid, eventMask: .exit, queue: queue
        )

        readSource.setEventHandler { [weak self] in self?.drainOutput() }
        // The fd may only be closed once the source is fully cancelled.
        readSource.setCancelHandler { close(master) }
        exitSource.setEventHandler { [weak self] in self?.reapChild() }
        readSource.resume()
        exitSource.resume()
    }

    deinit {
        if !closed {
            closed = true
            writeSource?.cancel()
            readSource.cancel()
        }
        if !exitSource.isCancelled { exitSource.cancel() }
    }

    // MARK: - I/O (all on `queue`)

    private func drainOutput() {
        guard !closed else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(masterFD, &buffer, buffer.count)
        if n > 0 {
            onOutput?(Data(buffer[0..<n]))
        } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
            // EOF / EIO: the child side is gone. Exit is reported by exitSource.
            closeMaster()
        }
    }

    private func reapChild() {
        exitSource.cancel()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let code: Int32
        if status & 0x7F == 0 {
            code = (status >> 8) & 0xFF // WIFEXITED / WEXITSTATUS
        } else {
            code = 128 + (status & 0x7F) // terminated by signal
        }
        // Deliver any output still buffered in the kernel before reporting exit.
        drainPendingOutputAfterExit()
        closeMaster()
        let onExit = self.onExit
        self.onExit = nil
        onExit?(code)
    }

    private func drainPendingOutputAfterExit() {
        guard !closed else { return }
        // The master is O_NONBLOCK for life (set at spawn), so the reads
        // below stop at EAGAIN instead of blocking.
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(masterFD, &buffer, buffer.count)
            guard n > 0 else { break }
            onOutput?(Data(buffer[0..<n]))
        }
    }

    private func closeMaster() {
        guard !closed else { return }
        closed = true
        pendingStdin.removeAll()
        // Cancelled first so it is off the fd before readSource's cancel
        // handler (queued after it on this serial queue) closes masterFD.
        writeSource?.cancel()
        writeSource = nil
        readSource.cancel() // the cancel handler closes masterFD
    }

    // MARK: - Thread-safe operations

    public func write(_ data: Data) {
        queue.async { [self] in
            guard !closed, !data.isEmpty else { return }
            guard pendingStdin.isEmpty else {
                // Earlier stdin is still queued; append behind it to keep order.
                bufferPendingStdin(data)
                return
            }
            let n = writeAvailable(data)
            guard n >= 0 else { return }
            if n < data.count { bufferPendingStdin(data.dropFirst(n)) }
        }
    }

    /// Writes as much as the tty accepts without blocking (the master is
    /// O_NONBLOCK). Returns the number of bytes consumed, or -1 on a hard
    /// error (child side gone; exit is reported by exitSource). On `queue`.
    private func writeAvailable(_ data: Data) -> Int {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(masterFD, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == EAGAIN { break }
                return -1
            }
            return offset
        }
    }

    /// Queues stdin the tty would not accept and arms `writeSource`. Beyond
    /// the cap the *newest* bytes are dropped: already-buffered bytes must
    /// keep flowing unbroken, or the child would read a stream with a hole
    /// spliced into its middle. On `queue`.
    private func bufferPendingStdin(_ data: Data) {
        let room = Self.maxPendingStdin - pendingStdin.count
        guard room > 0 else { return }
        pendingStdin.append(data.prefix(room))
        guard writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in self?.flushPendingStdin() }
        source.resume()
        writeSource = source
    }

    private func flushPendingStdin() {
        guard !closed, !pendingStdin.isEmpty else { return }
        let n = writeAvailable(pendingStdin)
        if n > 0 { pendingStdin.removeFirst(n) }
        if n < 0 { pendingStdin.removeAll() }
        if pendingStdin.isEmpty {
            writeSource?.cancel()
            writeSource = nil
        }
    }

    public func resize(cols: UInt16, rows: UInt16) {
        queue.async { [self] in
            guard !closed else { return }
            var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(masterFD, TIOCSWINSZ, &size)
        }
    }

    /// Every process' `p_comm` in the shell's process group, for the title
    /// fallback (PROTOCOL.md §6).
    ///
    /// The controlling terminal tracks the foreground job's process group, so
    /// this follows commands launched by an interactive shell instead of
    /// assuming they remain in the shell's own group. Must be called on the
    /// queue passed to `init`.
    public func foregroundProcessNames() -> [String] {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed else { return [] }
        let pgid = tcgetpgrp(masterFD)
        guard pgid > 0 else { return [] }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { proc in
            var proc = proc
            let name = withUnsafeBytes(of: &proc.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return name.isEmpty ? nil : name
        }
    }

    /// The shell's live working directory via `proc_pidinfo` (PROTOCOL.md §4:
    /// `cwd` in the sessions list is live). `cd` in the interactive shell moves
    /// it; nil when the process is gone or the query fails. Must be called on
    /// the queue passed to `init`.
    public func currentWorkingDirectory() -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    public func terminate() {
        // Kill the whole session (the shell and its children).
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
    }
}
