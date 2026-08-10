import Foundation

/// Incremental parser that extracts window titles from OSC 0/2 escape sequences in a raw
/// terminal output stream (PROTOCOL.md §6). Sequences may be split across arbitrary chunk
/// boundaries; terminators are BEL (0x07) or ST (ESC \).
public struct OSCTitleParser: Sendable {
    /// Titles longer than this are discarded (malformed / hostile stream protection).
    public static let maxTitleBytes = 4096

    private enum State: Sendable {
        case ground
        case escape                    // saw ESC
        case oscCode                   // inside "ESC ]", collecting numeric code
        case oscBody(isTitle: Bool)    // past "code;", collecting body (or skipping)
        case oscBodyEscape(isTitle: Bool) // saw ESC inside body; "\" completes ST
    }

    private var state: State = .ground
    private var code = ""
    private var body: [UInt8] = []
    private var bodyOverflowed = false

    public init() {}

    /// Feeds a chunk of raw PTY output; returns any complete OSC 0/2 titles found, in order.
    public mutating func consume(_ data: Data) -> [String] {
        var titles: [String] = []
        for byte in data {
            switch state {
            case .ground:
                if byte == 0x1B { state = .escape }
            case .escape:
                if byte == 0x5D { // ']'
                    state = .oscCode
                    code = ""
                } else if byte == 0x1B {
                    state = .escape
                } else {
                    state = .ground
                }
            case .oscCode:
                switch byte {
                case 0x30...0x39: // digit
                    if code.count < 8 { code.append(Character(UnicodeScalar(byte))) }
                case 0x3B: // ';'
                    let isTitle = code == "0" || code == "2"
                    body = []
                    bodyOverflowed = false
                    state = .oscBody(isTitle: isTitle)
                case 0x07: // BEL terminates a body-less OSC; no title
                    state = .ground
                case 0x1B:
                    state = .escape
                default: // non-numeric OSC (e.g. OSC 8 params with letters) — skip to terminator
                    body = []
                    bodyOverflowed = true
                    state = .oscBody(isTitle: false)
                }
            case .oscBody(let isTitle):
                switch byte {
                case 0x07: // BEL
                    if isTitle, let title = finishedTitle() { titles.append(title) }
                    state = .ground
                case 0x1B:
                    state = .oscBodyEscape(isTitle: isTitle)
                default:
                    collectBodyByte(byte)
                }
            case .oscBodyEscape(let isTitle):
                if byte == 0x5C { // '\' → ST
                    if isTitle, let title = finishedTitle() { titles.append(title) }
                    state = .ground
                } else if byte == 0x5D {
                    state = .oscCode
                    code = ""
                } else if byte == 0x1B {
                    state = .oscBodyEscape(isTitle: isTitle)
                } else {
                    // ESC inside OSC that is not ST: treat as abort of the OSC.
                    state = .ground
                }
            }
        }
        return titles
    }

    private mutating func collectBodyByte(_ byte: UInt8) {
        guard !bodyOverflowed else { return }
        if body.count >= Self.maxTitleBytes {
            bodyOverflowed = true
            body = []
        } else {
            body.append(byte)
        }
    }

    private mutating func finishedTitle() -> String? {
        defer { body = [] }
        guard !bodyOverflowed else { return nil }
        return String(decoding: body, as: UTF8.self)
    }
}
