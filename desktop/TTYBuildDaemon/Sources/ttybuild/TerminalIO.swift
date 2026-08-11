import Darwin
import Foundation

/// Local-tty plumbing for the attach client: raw mode, window size, and
/// escape-sequence helpers. All output goes straight to STDOUT_FILENO —
/// stdio buffering would reorder PTY bytes against control sequences.
enum TerminalIO {
    static func windowSize() -> (cols: UInt16, rows: UInt16) {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0,
              size.ws_col > 0, size.ws_row > 0
        else { return (80, 24) }
        return (size.ws_col, size.ws_row)
    }

    /// Enters raw mode and returns the termios to restore on exit.
    static func enterRawMode() -> termios? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        cfmakeraw(&raw)
        raw.c_cc.16 = 1 // VMIN
        raw.c_cc.17 = 0 // VTIME
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return nil }
        return original
    }

    static func restore(_ original: termios) {
        var copy = original
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &copy)
    }

    static func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(
                    STDOUT_FILENO, raw.baseAddress! + offset, raw.count - offset
                )
                if n <= 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += n
            }
        }
    }

    static func write(_ text: String) {
        write(Data(text.utf8))
    }

    /// Flushes pending, unread local input (buffered keystrokes must not
    /// reclaim a session the instant it is preempted).
    static func discardPendingInput() {
        tcflush(STDIN_FILENO, TCIFLUSH)
    }

    static func setWindowTitle(_ title: String) {
        let cleaned = title.replacingOccurrences(of: "\u{07}", with: " ")
            .replacingOccurrences(of: "\u{1B}", with: " ")
        write("\u{1B}]0;\(cleaned)\u{07}")
    }

    /// Full-screen placeholder: cleared screen, hidden cursor, a few centered
    /// lines. Black/white only, consistent with the product style.
    static func drawPlaceholder(title: String, lines: [String]) {
        let size = windowSize()
        var out = "\u{1B}[2J\u{1B}[H\u{1B}[?25l"
        let all = [title, ""] + lines
        let firstRow = max(1, (Int(size.rows) - all.count) / 2)
        for (index, line) in all.enumerated() {
            let column = max(1, (Int(size.cols) - line.count) / 2)
            out += "\u{1B}[\(firstRow + index);\(column)H"
            if index == 0 {
                out += "\u{1B}[1m\(line)\u{1B}[0m" // bold title
            } else {
                out += line
            }
        }
        write(out)
    }

    static func clearAndShowCursor() {
        write("\u{1B}[2J\u{1B}[H\u{1B}[?25h")
    }

    static func showCursor() {
        write("\u{1B}[?25h")
    }
}
