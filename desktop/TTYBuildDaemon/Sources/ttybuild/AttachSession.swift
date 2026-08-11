import Darwin
import Foundation
import TTYBuildDaemonCore
import TTYBuildKit

/// The interactive attach loop (docs/EXCLUSIVE_ATTACH_DESIGN.md §6).
///
/// Threads: the caller's thread runs the local-input loop (poll on stdin +
/// a self-pipe wakeup); one reader thread pumps daemon frames. State
/// transitions are lock-protected; terminal output is written directly.
final class AttachSession {
    private enum Mode {
        /// Passthrough: our stdin feeds the PTY, PTY output feeds our screen.
        case holding
        /// Someone else holds; the screen is a placeholder.
        case preempted(byName: String?)
        /// Nobody holds; the placeholder offers plain attach.
        case unheld
    }

    /// Grace for the double-press detach chord: a solo Ctrl-\ is forwarded
    /// after this window so the remote process keeps SIGQUIT reachable.
    private static let detachChordWindowMs: Int32 = 350
    private static let detachKey: UInt8 = 0x1C // Ctrl-\

    private let stream: AttachStream
    private let handshake: AttachStream.Handshake
    private let myPrincipal: String

    private let lock = NSLock()
    private var mode: Mode = .holding
    private var title: String
    private var finished: (code: Int32, message: String?)?

    /// Wakes the input loop's poll when the reader thread finishes the
    /// session (exit/close/EOF) or flips the mode.
    private let wakePipe = Pipe()

    init(stream: AttachStream, handshake: AttachStream.Handshake) {
        self.stream = stream
        self.handshake = handshake
        self.myPrincipal = "attach:\(handshake.connectionID)"
        self.title = handshake.title
    }

    /// Blocks until the session ends; returns the process exit code.
    func run() -> Int32 {
        guard let originalTermios = TerminalIO.enterRawMode() else {
            FileHandle.standardError.write(
                Data("ttybuild attach: stdin is not a tty\n".utf8)
            )
            return 1
        }
        defer {
            TerminalIO.restore(originalTermios)
            TerminalIO.showCursor()
        }

        TerminalIO.setWindowTitle(title.isEmpty ? "TTY.Build" : title)

        // SIGWINCH: resize the PTY while holding, re-center the placeholder
        // otherwise. SIGTERM/SIGHUP: restore the tty and leave.
        signal(SIGWINCH, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        winch.setEventHandler { [weak self] in self?.handleWindowChange() }
        winch.resume()
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        term.setEventHandler { [weak self] in
            self?.finish(code: 1, message: "terminated")
        }
        term.resume()
        let hup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
        hup.setEventHandler { [weak self] in
            self?.finish(code: 1, message: nil)
        }
        hup.resume()
        defer {
            winch.cancel()
            term.cancel()
            hup.cancel()
        }

        let reader = Thread { [weak self] in self?.readerLoop() }
        reader.name = "ttybuild-attach-reader"
        reader.start()

        // We hold on attach; assert this window's grid. The daemon has
        // already queued its replay, so this lands after it in order and the
        // SIGWINCH redraw fixes any wrapping difference.
        sendCurrentSize()

        inputLoop()

        stream.close()
        let result: (code: Int32, message: String?) =
            lock.withLock { finished } ?? (0, nil)
        if let message = result.message {
            TerminalIO.write("\r\n\(message)\r\n")
        }
        return result.code
    }

    // MARK: - Daemon-to-terminal (reader thread)

    private func readerLoop() {
        while true {
            let frame: Frame?
            do {
                frame = try stream.readFrame()
            } catch {
                finish(code: 1, message: "connection error: \(error)")
                return
            }
            guard let frame else {
                finish(code: 1, message: "connection closed by daemon")
                return
            }
            handle(frame: frame)
            if lock.withLock({ finished }) != nil { return }
        }
    }

    private func handle(frame: Frame) {
        switch frame.type {
        case .replay, .stdout:
            let render = lock.withLock {
                if case .holding = mode { return true }
                return false
            }
            if render { TerminalIO.write(frame.payload) }
            if frame.type == .replay, !handshake.alive {
                finish(code: 0, message: "[session already exited]")
            }
        case .resize:
            break // our own window is authoritative while we hold
        case .ctl:
            guard let message = try? frame.controlMessage() else { return }
            handle(control: message)
        case .stdin:
            break // client-to-daemon only
        }
    }

    private func handle(control message: ControlMessage) {
        switch message {
        case .takeover(let id, let holder):
            guard id == handshake.sessionId else { return }
            apply(holder: holder)
        case .title(let id, let newTitle):
            guard id == handshake.sessionId else { return }
            let redraw: Bool = lock.withLock {
                title = newTitle
                if case .holding = mode { return false }
                return true
            }
            TerminalIO.setWindowTitle(newTitle)
            if redraw { drawPlaceholder() }
        case .exit(let id, let code):
            guard id == handshake.sessionId else { return }
            finish(code: 0, message: "[session exited with code \(code)]")
        case .err(let message, _):
            finish(code: 0, message: "[\(message)]")
        default:
            break
        }
    }

    private func apply(holder: HolderInfo) {
        enum Transition { case toHolding, toPlaceholder, toReclaim, none }
        let transition: Transition = lock.withLock {
            let wasHolding: Bool
            if case .holding = mode { wasHolding = true } else { wasHolding = false }
            if holder.kind == .attach, holder.principal == myPrincipal {
                mode = .holding
                return wasHolding ? .none : .toHolding
            }
            if holder.kind == .none {
                mode = .unheld
                return .toReclaim
            }
            mode = .preempted(byName: holder.name ?? Self.fallbackName(holder))
            return .toPlaceholder
        }
        switch transition {
        case .toHolding:
            // The replay that follows our claim repaints the whole screen.
            TerminalIO.clearAndShowCursor()
        case .toPlaceholder:
            TerminalIO.discardPendingInput()
            drawPlaceholder()
        case .toReclaim:
            // Nobody holds the session (the holder detached or died): race
            // to claim it rather than parking on a "Not attached"
            // placeholder — every surface does this, and the arbiter's
            // last-writer-wins settles simultaneous claims. The screen
            // stays as-is until the answering takeover + replay repaint
            // it; input typed meanwhile belongs to the previous holder's
            // view of the world, so drop it.
            TerminalIO.discardPendingInput()
            try? stream.send(
                Frame.control(.claim(id: handshake.sessionId, req: nil))
            )
            sendCurrentSize()
        case .none:
            break
        }
    }

    private static func fallbackName(_ holder: HolderInfo) -> String? {
        switch holder.kind {
        case .client: "iPhone"
        case .attach: "another terminal"
        case .none: nil
        }
    }

    private func drawPlaceholder() {
        let (currentTitle, lines): (String, [String]) = lock.withLock {
            switch mode {
            case .holding:
                return (title, [])
            case .preempted(let name):
                return (title, [
                    "In use on \(name ?? "another device")",
                    "",
                    "press ⏎ to take over · q to quit",
                ])
            case .unheld:
                return (title, [
                    "Not attached",
                    "",
                    "press ⏎ to attach · q to quit",
                ])
            }
        }
        guard !lines.isEmpty else { return }
        TerminalIO.drawPlaceholder(
            title: currentTitle.isEmpty ? "TTY.Build" : currentTitle,
            lines: lines
        )
    }

    // MARK: - Terminal-to-daemon (caller thread)

    private func inputLoop() {
        let wakeFD = wakePipe.fileHandleForReading.fileDescriptor
        var pendingDetachByte = false

        while lock.withLock({ finished }) == nil {
            var fds = [
                pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0),
            ]
            let timeout = pendingDetachByte ? Self.detachChordWindowMs : -1
            let ready = poll(&fds, 2, timeout)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0, pendingDetachByte {
                // Chord window elapsed: the solo Ctrl-\ was meant for the
                // remote process after all.
                pendingDetachByte = false
                sendStdin(Data([Self.detachKey]))
                continue
            }
            if fds[1].revents != 0 { return } // reader thread finished us
            guard fds[0].revents != 0 else { continue }

            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let n = read(STDIN_FILENO, &chunk, chunk.count)
            guard n > 0 else { return } // local tty is gone
            let data = Data(chunk[0..<n])

            let isHolding: Bool = lock.withLock {
                if case .holding = mode { return true }
                return false
            }
            if isHolding {
                if pendingDetachByte {
                    pendingDetachByte = false
                    if n == 1, chunk[0] == Self.detachKey {
                        finish(code: 0, message: "[detached]")
                        return
                    }
                    sendStdin(Data([Self.detachKey]))
                    sendStdin(data)
                } else if n == 1, chunk[0] == Self.detachKey {
                    pendingDetachByte = true
                } else {
                    sendStdin(data)
                }
            } else {
                pendingDetachByte = false
                handlePlaceholderKeys(data)
            }
        }
    }

    private func handlePlaceholderKeys(_ data: Data) {
        for byte in data {
            switch byte {
            case 0x0D, 0x0A, UInt8(ascii: "t"), UInt8(ascii: "T"):
                try? stream.send(
                    Frame.control(.claim(id: handshake.sessionId, req: nil))
                )
                sendCurrentSize()
                return
            case UInt8(ascii: "q"), UInt8(ascii: "Q"), 0x03: // q / Ctrl-C
                finish(code: 0, message: nil)
                return
            default:
                continue
            }
        }
    }

    private func sendStdin(_ data: Data) {
        try? stream.send(
            Frame.stdin(sessionId: UInt32(handshake.sessionId), data: data)
        )
    }

    private func sendCurrentSize() {
        let size = TerminalIO.windowSize()
        try? stream.send(Frame.resize(
            sessionId: UInt32(handshake.sessionId),
            cols: size.cols, rows: size.rows
        ))
    }

    private func handleWindowChange() {
        let isHolding: Bool = lock.withLock {
            if case .holding = mode { return true }
            return false
        }
        if isHolding {
            sendCurrentSize()
        } else {
            drawPlaceholder()
        }
    }

    // MARK: - Termination

    private func finish(code: Int32, message: String?) {
        let first: Bool = lock.withLock {
            guard finished == nil else { return false }
            finished = (code, message)
            return true
        }
        guard first else { return }
        // Wake the poll in the input loop.
        wakePipe.fileHandleForWriting.write(Data([1]))
    }
}
