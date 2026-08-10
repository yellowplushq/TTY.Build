import Foundation
import GhosttyTerminal

/// A mode 2048 in-band size report (`CSI 48 ; rows ; cols ; hpx ; wpx t`).
///
/// Ghostty emits this report through the host input channel from the same
/// termio critical section that applies a grid resize to terminal state, so a
/// report is the authoritative signal that all subsequently parsed bytes meet
/// a grid of at least this size. TTYBuild strips reports out of the input
/// stream (the remote pty must never receive them as keystrokes) and treats
/// them as applied-resize events — the only safe trigger for `resize` frames.
struct TerminalSizeReport: Equatable {
    var rows: UInt16
    var columns: UInt16
    var heightPixels: UInt32
    var widthPixels: UInt32

    /// The escape sequence that enables mode 2048. Enabling is idempotent,
    /// survives grid resizes (only a full reset clears it), and makes the
    /// terminal emit one immediate report for the current grid.
    static let enableSequence = Data("\u{1b}[?2048h".utf8)

    /// Reports are short; anything longer than this cannot be one.
    private static let maximumSequenceLength = 40

    var viewport: InMemoryTerminalViewport {
        InMemoryTerminalViewport(
            columns: columns,
            rows: rows,
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            cellWidthPixels: columns > 0 ? widthPixels / UInt32(columns) : 0,
            cellHeightPixels: rows > 0 ? heightPixels / UInt32(rows) : 0
        )
    }

    /// Splits `data` into host-bound bytes and any embedded size reports.
    ///
    /// Ghostty writes each report as a single buffer, so reports never span
    /// chunk boundaries. Malformed candidates pass through untouched.
    static func extract(
        from data: Data
    ) -> (passthrough: Data, reports: [TerminalSizeReport]) {
        guard data.contains(0x1B) else { return (data, []) }

        let bytes = [UInt8](data)
        var passthrough = [UInt8]()
        passthrough.reserveCapacity(bytes.count)
        var reports = [TerminalSizeReport]()
        var index = 0

        while index < bytes.count {
            guard bytes[index] == 0x1B,
                  let parsed = parse(bytes, at: index)
            else {
                passthrough.append(bytes[index])
                index += 1
                continue
            }

            reports.append(parsed.report)
            index = parsed.end
        }

        return (Data(passthrough), reports)
    }

    /// Parses one report starting at `start` (which must point at ESC).
    /// Returns the report and the index just past its final `t`.
    private static func parse(
        _ bytes: [UInt8],
        at start: Int
    ) -> (report: TerminalSizeReport, end: Int)? {
        let prefix: [UInt8] = Array("\u{1b}[48;".utf8)
        guard bytes.count - start > prefix.count,
              Array(bytes[start ..< start + prefix.count]) == prefix
        else { return nil }

        var fields: [UInt64] = []
        var current: UInt64? = nil
        var index = start + prefix.count
        let limit = min(bytes.count, start + maximumSequenceLength)

        while index < limit {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                current = (current ?? 0) * 10 + UInt64(byte - UInt8(ascii: "0"))
                guard current! <= UInt64(UInt32.max) else { return nil }
            case UInt8(ascii: ";"):
                guard let value = current, fields.count < 3 else { return nil }
                fields.append(value)
                current = nil
            case UInt8(ascii: "t"):
                guard let value = current, fields.count == 3 else { return nil }
                fields.append(value)
                guard let rows = UInt16(exactly: fields[0]),
                      let columns = UInt16(exactly: fields[1])
                else { return nil }
                return (
                    TerminalSizeReport(
                        rows: rows,
                        columns: columns,
                        heightPixels: UInt32(fields[2]),
                        widthPixels: UInt32(fields[3])
                    ),
                    index + 1
                )
            default:
                return nil
            }
            index += 1
        }

        return nil
    }
}
