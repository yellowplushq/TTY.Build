import Foundation

/// Splits a replay snapshot into the history the user saw and the trailing
/// run of control sequences after the last visible character.
///
/// Queries inside the history were already answered by whichever terminal was
/// attached when they ran, so their replies are muted during a replay. The
/// trailing run is different: a process can still be blocked on a query there
/// (fish 4.x waits for its startup Primary Device Attributes reply before it
/// prints anything), and nothing has answered it yet. The host feeds that run
/// only after the history is parsed, with replies flowing to the PTY.
enum TerminalReplayTail {
    /// Returns the index where the trailing control-only run begins, or
    /// `data.count` when the snapshot ends in visible output.
    ///
    /// Bytes inside escape sequences (CSI, OSC, DCS/SOS/PM/APC strings and
    /// short ESC sequences) are never visible, nor are C0 controls; everything
    /// else, including UTF-8 continuation bytes, is.
    static func pendingStart(in data: Data) -> Int {
        let bytes = [UInt8](data)
        var pendingStart = 0
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B {
                index = sequenceEnd(bytes, from: index)
            } else {
                index += 1
                if byte >= 0x20, byte != 0x7F {
                    pendingStart = index
                }
            }
        }
        return pendingStart
    }

    static func split(_ data: Data) -> (history: Data, pending: Data) {
        let start = data.startIndex + pendingStart(in: data)
        return (data[data.startIndex ..< start], data[start...])
    }

    /// Index just past the escape sequence starting at `start` (an ESC). An
    /// unterminated sequence runs to the end of the data.
    private static func sequenceEnd(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start + 1
        guard index < bytes.count else { return index }

        switch bytes[index] {
        case UInt8(ascii: "["):
            // CSI: parameter and intermediate bytes, then one final byte.
            index += 1
            while index < bytes.count, !(0x40 ... 0x7E).contains(bytes[index]) {
                index += 1
            }
            return min(index + 1, bytes.count)
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"),
             UInt8(ascii: "^"), UInt8(ascii: "_"):
            // OSC / DCS / SOS / PM / APC: until ST (ESC \), or BEL for OSC.
            let acceptsBell = bytes[index] == UInt8(ascii: "]")
            index += 1
            while index < bytes.count {
                if acceptsBell, bytes[index] == 0x07 { return index + 1 }
                if bytes[index] == 0x1B, index + 1 < bytes.count,
                   bytes[index + 1] == UInt8(ascii: "\\")
                {
                    return index + 2
                }
                index += 1
            }
            return index
        default:
            // nF intermediates (ESC ( B, ESC # 8, …), then one final byte.
            while index < bytes.count, (0x20 ... 0x2F).contains(bytes[index]) {
                index += 1
            }
            return min(index + 1, bytes.count)
        }
    }
}
