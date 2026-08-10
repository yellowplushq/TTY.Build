import Foundation

/// A lightweight, renderer-independent terminal projection for small clients.
///
/// This intentionally focuses on the control sequences commonly emitted by
/// shells, progress indicators, and command-line agents. It maintains a cell
/// grid so carriage-return updates and cursor-addressed output are applied
/// before a small UI displays the fixed terminal rows without reflowing them.
public struct TerminalTextProjection: Sendable {
    public enum Color: Equatable, Sendable {
        case indexed(UInt8)
        case rgb(red: UInt8, green: UInt8, blue: UInt8)
    }

    public struct Style: Equatable, Sendable {
        public var foreground: Color?
        public var background: Color?
        public var bold: Bool
        public var faint: Bool
        public var italic: Bool
        public var underlined: Bool
        public var inverted: Bool

        public init(
            foreground: Color? = nil,
            background: Color? = nil,
            bold: Bool = false,
            faint: Bool = false,
            italic: Bool = false,
            underlined: Bool = false,
            inverted: Bool = false
        ) {
            self.foreground = foreground
            self.background = background
            self.bold = bold
            self.faint = faint
            self.italic = italic
            self.underlined = underlined
            self.inverted = inverted
        }
    }

    public struct Run: Equatable, Sendable {
        public let text: String
        public let style: Style

        public init(text: String, style: Style) {
            self.text = text
            self.style = style
        }
    }

    public struct Line: Identifiable, Equatable, Sendable {
        public let id: UInt64
        public let text: String
        public let runs: [Run]

        public init(id: UInt64, text: String, runs: [Run]? = nil) {
            self.id = id
            self.text = text
            self.runs = runs ?? [Run(text: text, style: Style())]
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let revision: UInt64
        public let columns: Int
        public let rows: Int
        public let lines: [Line]
        public let alternateScreen: Bool
        public let mouseTracking: Bool
        public let sgrMouseEncoding: Bool

        public init(
            revision: UInt64,
            columns: Int,
            rows: Int,
            lines: [Line],
            alternateScreen: Bool,
            mouseTracking: Bool = false,
            sgrMouseEncoding: Bool = false
        ) {
            self.revision = revision
            self.columns = columns
            self.rows = rows
            self.lines = lines
            self.alternateScreen = alternateScreen
            self.mouseTracking = mouseTracking
            self.sgrMouseEncoding = sgrMouseEncoding
        }

        public var text: String {
            lines.map(\.text).joined(separator: "\n")
        }

        /// Materialized rows in the current TTY viewport. `lines` also keeps
        /// bounded scrollback for clients that need it; a fixed-screen
        /// renderer must use this suffix so repeated height changes never
        /// accumulate older screens in its scrollable content.
        public var viewportLines: [Line] {
            Array(lines.suffix(rows))
        }
    }

    private enum Cell: Equatable, Sendable {
        case blank(Style)
        case glyph(Character, width: Int, style: Style)
        case continuation(Style)

        var style: Style {
            switch self {
            case .blank(let style), .continuation(let style), .glyph(_, _, let style):
                style
            }
        }

        var isTrimmable: Bool {
            switch self {
            case .blank(let style):
                style == Style()
            case .continuation:
                true
            case .glyph:
                false
            }
        }
    }

    private struct GridLine: Equatable, Sendable {
        let id: UInt64
        var cells: [Cell] = []
        var softWrapsNext = false

        var text: String {
            var end = cells.count
            while end > 0, cells[end - 1].isTrimmable {
                end -= 1
            }
            guard end > 0 else { return "" }

            var value = ""
            for cell in cells[..<end] {
                switch cell {
                case .blank:
                    value.append(" ")
                case .glyph(let character, _, _):
                    value.append(character)
                case .continuation:
                    break
                }
            }
            return value
        }

        var runs: [Run] {
            var end = cells.count
            while end > 0, cells[end - 1].isTrimmable { end -= 1 }
            guard end > 0 else { return [] }

            var result: [Run] = []
            var text = ""
            var style: Style?
            func appendRun() {
                guard !text.isEmpty, let style else { return }
                result.append(Run(text: text, style: style))
            }

            for cell in cells[..<end] {
                guard case .continuation = cell else {
                    if style != cell.style {
                        appendRun()
                        text = ""
                        style = cell.style
                    }
                    switch cell {
                    case .blank:
                        text.append(" ")
                    case .glyph(let character, _, _):
                        text.append(character)
                    case .continuation:
                        break
                    }
                    continue
                }
            }
            appendRun()
            return result
        }
    }

    private enum ParserState: Sendable {
        case ground
        case escape
        case escapeIntermediate
        case csi([UInt8])
        case string(escapePending: Bool)
    }

    private var columns: Int
    private var rows: Int
    private var maximumLineCount: Int
    private var lines: [GridLine] = []
    private var cursorRow = 0
    private var cursorColumn = 0
    private var savedCursor: (row: Int, column: Int)?
    private var nextLineID: UInt64 = 1
    private var parserState: ParserState = .ground
    private var printableBytes = Data()
    private var alternateScreen = false
    private var mouseTracking = false
    private var sgrMouseEncoding = false
    private var currentStyle = Style()
    private var revision: UInt64 = 0

    public init(cols: Int, rows: Int, maximumLineCount: Int = 1_000) {
        columns = min(max(cols, 2), 512)
        self.rows = min(max(rows, 2), 256)
        self.maximumLineCount = max(maximumLineCount, self.rows)
        appendLine()
    }

    /// Clears all parser and grid state. IDs remain monotonic so SwiftUI never
    /// mistakes new replay rows for stale rows from the previous snapshot.
    public mutating func reset() {
        lines.removeAll(keepingCapacity: true)
        cursorRow = 0
        cursorColumn = 0
        savedCursor = nil
        parserState = .ground
        printableBytes.removeAll(keepingCapacity: true)
        alternateScreen = false
        mouseTracking = false
        sgrMouseEncoding = false
        currentStyle = Style()
        revision &+= 1
        appendLine()
    }

    /// Updates the coordinate space used for subsequent cursor-addressed
    /// output. Existing rows keep their positions and are clipped only when
    /// the terminal becomes narrower. When the terminal grows taller, new
    /// active-screen rows are appended so existing scrollback never becomes
    /// part of the writable TTY screen again. The host normally follows a PTY
    /// resize with a complete TUI redraw.
    public mutating func resize(cols: Int, rows: Int) {
        let columns = min(max(cols, 2), 512)
        let rows = min(max(rows, 2), 256)
        guard columns != self.columns || rows != self.rows else { return }

        if rows > self.rows {
            for _ in 0 ..< (rows - self.rows) { appendLine() }
        }
        self.columns = columns
        self.rows = rows
        maximumLineCount = max(maximumLineCount, rows)
        for index in lines.indices where lines[index].cells.count > columns {
            lines[index].cells.removeLast(lines[index].cells.count - columns)
            if case .continuation = lines[index].cells.last, columns > 1 {
                lines[index].cells[columns - 1] = .blank(Style())
                if case .glyph(_, let width, _) = lines[index].cells[columns - 2], width == 2 {
                    lines[index].cells[columns - 2] = .blank(Style())
                }
            }
        }
        trimScrollbackIfNeeded()
        cursorRow = min(max(cursorRow, screenTop), screenTop + rows - 1)
        cursorColumn = min(cursorColumn, columns - 1)
        if let savedCursor {
            self.savedCursor = (
                min(max(savedCursor.row, screenTop), screenTop + rows - 1),
                min(savedCursor.column, columns - 1)
            )
        }
        revision &+= 1
    }

    /// Consumes one arbitrary chunk of PTY bytes. UTF-8 and escape sequences
    /// may be split across calls.
    public mutating func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        for byte in data {
            consume(byte)
        }
        flushPrintable(forceIncomplete: false)
        trimScrollbackIfNeeded()
        revision &+= 1
    }

    public var snapshot: Snapshot {
        var projected = lines.map { Line(id: $0.id, text: $0.text, runs: $0.runs) }
        if projected.isEmpty {
            projected = [Line(id: 0, text: "")]
        }
        return Snapshot(
            revision: revision,
            columns: columns,
            rows: rows,
            lines: projected,
            alternateScreen: alternateScreen,
            mouseTracking: mouseTracking,
            sgrMouseEncoding: sgrMouseEncoding
        )
    }

    private mutating func consume(_ byte: UInt8) {
        switch parserState {
        case .ground:
            switch byte {
            case 0x1B:
                flushPrintable(forceIncomplete: true)
                parserState = .escape
            case 0x0A, 0x0B, 0x0C:
                flushPrintable(forceIncomplete: true)
                // PTYs normally translate NL to CRLF. Treat a bare NL the
                // same way for readable projections from hosts that disable
                // output post-processing.
                cursorColumn = 0
                lineFeed()
            case 0x0D:
                flushPrintable(forceIncomplete: true)
                cursorColumn = 0
            case 0x08:
                flushPrintable(forceIncomplete: true)
                cursorColumn = max(0, cursorColumn - 1)
            case 0x09:
                flushPrintable(forceIncomplete: true)
                cursorColumn = min(columns - 1, ((cursorColumn / 8) + 1) * 8)
            case 0x00 ... 0x1F, 0x7F:
                flushPrintable(forceIncomplete: true)
            default:
                printableBytes.append(byte)
            }

        case .escape:
            switch byte {
            case 0x5B: // [
                parserState = .csi([])
            case 0x5D, 0x50, 0x5E, 0x5F: // OSC, DCS, PM, APC
                parserState = .string(escapePending: false)
            case 0x20 ... 0x2F:
                // ISO-2022 character-set designators such as ESC ( B have
                // one or more intermediate bytes followed by a final byte.
                // The projection stays Unicode, but it must consume the whole
                // sequence so the final byte never leaks into the grid.
                parserState = .escapeIntermediate
            case 0x37: // DECSC
                savedCursor = (cursorRow, cursorColumn)
                parserState = .ground
            case 0x38: // DECRC
                restoreCursor()
                parserState = .ground
            case 0x63: // RIS
                reset()
            default:
                parserState = .ground
            }

        case .escapeIntermediate:
            if (0x30 ... 0x7E).contains(byte) {
                parserState = .ground
            } else if !(0x20 ... 0x2F).contains(byte) {
                parserState = .ground
            }

        case .csi(var bytes):
            if (0x40 ... 0x7E).contains(byte) {
                applyCSI(parameters: bytes, final: byte)
                parserState = .ground
            } else if bytes.count < 128 {
                bytes.append(byte)
                parserState = .csi(bytes)
            } else {
                parserState = .ground
            }

        case .string(let escapePending):
            if byte == 0x07 { // BEL terminates OSC
                parserState = .ground
            } else if escapePending, byte == 0x5C { // ST (ESC \\)
                parserState = .ground
            } else {
                parserState = .string(escapePending: byte == 0x1B)
            }
        }
    }

    private mutating func flushPrintable(forceIncomplete: Bool) {
        guard !printableBytes.isEmpty else { return }
        let length = forceIncomplete
            ? printableBytes.count
            : Self.completeUTF8PrefixLength(printableBytes)
        guard length > 0 else { return }

        let prefix = printableBytes.prefix(length)
        printableBytes.removeFirst(length)
        for character in String(decoding: prefix, as: UTF8.self) {
            write(character)
        }
    }

    private mutating func write(_ character: Character) {
        if Self.isCombining(character), cursorColumn > 0 {
            appendCombining(character)
            return
        }

        let width = Self.cellWidth(of: character)
        if cursorColumn + width > columns {
            cursorColumn = 0
            lineFeed(softWrapped: true)
        }

        ensureLine(cursorRow)
        clearGlyph(at: cursorColumn, row: cursorRow)
        if width == 2 { clearGlyph(at: cursorColumn + 1, row: cursorRow) }
        ensureCells(row: cursorRow, through: cursorColumn + width - 1)
        lines[cursorRow].cells[cursorColumn] = .glyph(
            character,
            width: width,
            style: currentStyle
        )
        if width == 2 {
            lines[cursorRow].cells[cursorColumn + 1] = .continuation(currentStyle)
        }
        cursorColumn += width
    }

    private mutating func appendCombining(_ character: Character) {
        ensureLine(cursorRow)
        var index = min(cursorColumn - 1, lines[cursorRow].cells.count - 1)
        while index >= 0 {
            switch lines[cursorRow].cells[index] {
            case .glyph(let base, let width, let style):
                let combined = Character(String(base) + String(character))
                lines[cursorRow].cells[index] = .glyph(
                    combined,
                    width: width,
                    style: style
                )
                return
            case .blank, .continuation:
                index -= 1
            }
        }
    }

    private mutating func lineFeed(softWrapped: Bool = false) {
        lines[cursorRow].softWrapsNext = softWrapped
        cursorRow += 1
        ensureLine(cursorRow)
        trimScrollbackIfNeeded()
    }

    private mutating func applyCSI(parameters bytes: [UInt8], final: UInt8) {
        let raw = String(decoding: bytes, as: UTF8.self)
        let privateMode = raw.hasPrefix("?")
        let body = privateMode ? String(raw.dropFirst()) : raw
        let parameters = body.split(separator: ";", omittingEmptySubsequences: false).map {
            Int($0.split(separator: ":", maxSplits: 1).first ?? "")
        }
        func parameter(_ index: Int, default fallback: Int) -> Int {
            guard parameters.indices.contains(index), let value = parameters[index], value != 0
            else { return fallback }
            return value
        }

        switch final {
        case 0x40: // ICH
            insertBlankCells(count: parameter(0, default: 1))
        case 0x41: // CUU
            moveCursor(rowDelta: -parameter(0, default: 1), columnDelta: 0)
        case 0x42, 0x65: // CUD, VPR
            moveCursor(rowDelta: parameter(0, default: 1), columnDelta: 0)
        case 0x43, 0x61: // CUF, HPR
            cursorColumn = min(columns - 1, cursorColumn + parameter(0, default: 1))
        case 0x44: // CUB
            cursorColumn = max(0, cursorColumn - parameter(0, default: 1))
        case 0x45: // CNL
            moveCursor(rowDelta: parameter(0, default: 1), columnDelta: 0)
            cursorColumn = 0
        case 0x46: // CPL
            moveCursor(rowDelta: -parameter(0, default: 1), columnDelta: 0)
            cursorColumn = 0
        case 0x47, 0x60: // CHA, HPA
            cursorColumn = min(columns - 1, parameter(0, default: 1) - 1)
        case 0x48, 0x66: // CUP, HVP
            setCursor(row: parameter(0, default: 1), column: parameter(1, default: 1))
        case 0x4A: // ED
            eraseDisplay(mode: parameters.first.flatMap { $0 } ?? 0)
        case 0x4B: // EL
            eraseLine(mode: parameters.first.flatMap { $0 } ?? 0)
        case 0x4C: // IL
            insertLines(count: parameter(0, default: 1))
        case 0x4D: // DL
            deleteLines(count: parameter(0, default: 1))
        case 0x50: // DCH
            deleteCells(count: parameter(0, default: 1))
        case 0x58: // ECH
            eraseCells(count: parameter(0, default: 1))
        case 0x64: // VPA
            setCursor(row: parameter(0, default: 1), column: cursorColumn + 1)
        case 0x6D: // SGR
            applySGR(body)
        case 0x68 where privateMode: // DECSET
            if parameters.contains(where: { $0 == 47 || $0 == 1047 || $0 == 1049 }) {
                alternateScreen = true
            }
            if parameters.contains(where: { $0 == 1000 || $0 == 1002 || $0 == 1003 }) {
                mouseTracking = true
            }
            if parameters.contains(where: { $0 == 1006 }) { sgrMouseEncoding = true }
        case 0x6C where privateMode: // DECRST
            if parameters.contains(where: { $0 == 47 || $0 == 1047 || $0 == 1049 }) {
                alternateScreen = false
            }
            if parameters.contains(where: { $0 == 1000 || $0 == 1002 || $0 == 1003 }) {
                mouseTracking = false
            }
            if parameters.contains(where: { $0 == 1006 }) { sgrMouseEncoding = false }
        case 0x73: // SCP
            savedCursor = (cursorRow, cursorColumn)
        case 0x75: // RCP
            restoreCursor()
        default:
            break // styling and unsupported modes do not affect plain text
        }
    }

    private mutating func applySGR(_ raw: String) {
        let values = raw.replacingOccurrences(of: ":", with: ";")
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        let codes = values.isEmpty ? [0] : values
        var index = 0

        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0:
                currentStyle = Style()
            case 1:
                currentStyle.bold = true
            case 2:
                currentStyle.faint = true
            case 3:
                currentStyle.italic = true
            case 4, 21:
                currentStyle.underlined = true
            case 7:
                currentStyle.inverted = true
            case 22:
                currentStyle.bold = false
                currentStyle.faint = false
            case 23:
                currentStyle.italic = false
            case 24:
                currentStyle.underlined = false
            case 27:
                currentStyle.inverted = false
            case 30 ... 37:
                currentStyle.foreground = .indexed(UInt8(code - 30))
            case 39:
                currentStyle.foreground = nil
            case 40 ... 47:
                currentStyle.background = .indexed(UInt8(code - 40))
            case 49:
                currentStyle.background = nil
            case 90 ... 97:
                currentStyle.foreground = .indexed(UInt8(code - 90 + 8))
            case 100 ... 107:
                currentStyle.background = .indexed(UInt8(code - 100 + 8))
            case 38, 48:
                let foreground = code == 38
                if index + 2 < codes.count, codes[index + 1] == 5 {
                    let color = Color.indexed(UInt8(clamping: codes[index + 2]))
                    if foreground {
                        currentStyle.foreground = color
                    } else {
                        currentStyle.background = color
                    }
                    index += 2
                } else if index + 4 < codes.count, codes[index + 1] == 2 {
                    let color = Color.rgb(
                        red: UInt8(clamping: codes[index + 2]),
                        green: UInt8(clamping: codes[index + 3]),
                        blue: UInt8(clamping: codes[index + 4])
                    )
                    if foreground {
                        currentStyle.foreground = color
                    } else {
                        currentStyle.background = color
                    }
                    index += 4
                }
            default:
                break
            }
            index += 1
        }
    }

    private var screenTop: Int {
        max(0, lines.count - rows)
    }

    private mutating func setCursor(row: Int, column: Int) {
        cursorRow = screenTop + min(max(row - 1, 0), rows - 1)
        cursorColumn = min(max(column - 1, 0), columns - 1)
        ensureLine(cursorRow)
    }

    private mutating func moveCursor(rowDelta: Int, columnDelta: Int) {
        cursorRow = min(max(screenTop, cursorRow + rowDelta), screenTop + rows - 1)
        cursorColumn = min(max(0, cursorColumn + columnDelta), columns - 1)
        ensureLine(cursorRow)
    }

    private mutating func restoreCursor() {
        guard let savedCursor else { return }
        cursorRow = max(0, savedCursor.row)
        cursorColumn = min(max(0, savedCursor.column), columns - 1)
        ensureLine(cursorRow)
    }

    private mutating func eraseLine(mode: Int) {
        ensureLine(cursorRow)
        switch mode {
        case 1:
            ensureCells(row: cursorRow, through: cursorColumn)
            for column in 0 ... cursorColumn { clearGlyph(at: column, row: cursorRow) }
        case 2:
            lines[cursorRow].cells = Array(
                repeating: .blank(currentStyle),
                count: columns
            )
        default:
            if cursorColumn < columns {
                ensureCells(row: cursorRow, through: columns - 1)
                for column in cursorColumn ..< columns {
                    clearGlyph(at: column, row: cursorRow)
                }
            }
        }
    }

    private mutating func eraseDisplay(mode: Int) {
        ensureLine(cursorRow)
        switch mode {
        case 1:
            eraseLine(mode: 1)
            if cursorRow > screenTop {
                for row in screenTop ..< cursorRow {
                    lines[row].cells.removeAll(keepingCapacity: true)
                    lines[row].softWrapsNext = false
                }
            }
        case 2:
            let end = min(lines.count, screenTop + rows)
            for row in screenTop ..< end {
                lines[row].cells.removeAll(keepingCapacity: true)
                lines[row].softWrapsNext = false
            }
        case 3:
            guard screenTop > 0 else { return }
            lines.removeFirst(screenTop)
            cursorRow -= screenTop
            if let savedCursor {
                self.savedCursor = (max(0, savedCursor.row - screenTop), savedCursor.column)
            }
        default:
            eraseLine(mode: 0)
            let end = min(lines.count, screenTop + rows)
            if cursorRow + 1 < end {
                for row in (cursorRow + 1) ..< end {
                    lines[row].cells.removeAll(keepingCapacity: true)
                    lines[row].softWrapsNext = false
                }
            }
        }
    }

    private mutating func insertBlankCells(count: Int) {
        ensureLine(cursorRow)
        let count = min(max(count, 0), columns - cursorColumn)
        guard count > 0 else { return }
        ensureCells(row: cursorRow, through: cursorColumn - 1)
        lines[cursorRow].cells.insert(
            contentsOf: repeatElement(.blank(currentStyle), count: count), at: cursorColumn
        )
        if lines[cursorRow].cells.count > columns {
            lines[cursorRow].cells.removeLast(lines[cursorRow].cells.count - columns)
        }
    }

    private mutating func deleteCells(count: Int) {
        ensureLine(cursorRow)
        guard cursorColumn < lines[cursorRow].cells.count else { return }
        let end = min(lines[cursorRow].cells.count, cursorColumn + max(count, 0))
        lines[cursorRow].cells.removeSubrange(cursorColumn ..< end)
    }

    private mutating func eraseCells(count: Int) {
        ensureLine(cursorRow)
        let end = min(columns, cursorColumn + max(count, 0))
        guard end > cursorColumn else { return }
        ensureCells(row: cursorRow, through: end - 1)
        for column in cursorColumn ..< end { clearGlyph(at: column, row: cursorRow) }
    }

    private mutating func insertLines(count: Int) {
        let count = min(max(count, 0), rows)
        guard count > 0 else { return }
        for _ in 0 ..< count {
            lines.insert(makeLine(), at: min(cursorRow, lines.count))
        }
        cursorRow = min(cursorRow, lines.count - 1)
        trimScrollbackIfNeeded()
    }

    private mutating func deleteLines(count: Int) {
        let available = min(max(count, 0), lines.count - cursorRow)
        guard available > 0 else { return }
        lines.removeSubrange(cursorRow ..< cursorRow + available)
        while lines.count <= cursorRow { appendLine() }
    }

    private mutating func clearGlyph(at column: Int, row: Int) {
        guard row >= 0, row < lines.count,
              column >= 0, column < lines[row].cells.count
        else { return }
        switch lines[row].cells[column] {
        case .blank:
            break
        case .glyph(_, let width, _):
            lines[row].cells[column] = .blank(currentStyle)
            if width == 2, column + 1 < lines[row].cells.count {
                lines[row].cells[column + 1] = .blank(currentStyle)
            }
        case .continuation:
            lines[row].cells[column] = .blank(currentStyle)
            if column > 0,
               case .glyph(_, let width, _) = lines[row].cells[column - 1],
               width == 2
            {
                lines[row].cells[column - 1] = .blank(currentStyle)
            }
        }
    }

    private mutating func ensureLine(_ row: Int) {
        while lines.count <= row { appendLine() }
    }

    private mutating func ensureCells(row: Int, through column: Int) {
        guard column >= 0 else { return }
        ensureLine(row)
        if lines[row].cells.count <= column {
            lines[row].cells.append(contentsOf: repeatElement(
                .blank(Style()), count: column + 1 - lines[row].cells.count
            ))
        }
    }

    private mutating func appendLine() {
        lines.append(makeLine())
    }

    private mutating func makeLine() -> GridLine {
        defer { nextLineID &+= 1 }
        return GridLine(id: nextLineID)
    }

    private mutating func trimScrollbackIfNeeded() {
        let excess = lines.count - maximumLineCount
        guard excess > 0 else { return }
        lines.removeFirst(excess)
        cursorRow = max(0, cursorRow - excess)
        if let savedCursor {
            self.savedCursor = (max(0, savedCursor.row - excess), savedCursor.column)
        }
    }

    private static func completeUTF8PrefixLength(_ data: Data) -> Int {
        let bytes = Array(data)
        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            let length: Int
            switch first {
            case 0x00 ... 0x7F:
                length = 1
            case 0xC2 ... 0xDF:
                length = 2
            case 0xE0 ... 0xEF:
                length = 3
            case 0xF0 ... 0xF4:
                length = 4
            default:
                index += 1 // invalid byte; String(decoding:) will replace it
                continue
            }
            guard index + length <= bytes.count else { return index }
            let continuation = bytes[(index + 1) ..< (index + length)]
            guard continuation.allSatisfy({ (0x80 ... 0xBF).contains($0) }) else {
                index += 1
                continue
            }
            index += length
        }
        return index
    }

    private static func isCombining(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let category = character.unicodeScalars.first?.properties.generalCategory
        else { return false }
        return category == .nonspacingMark
            || category == .spacingMark
            || category == .enclosingMark
    }

    /// Terminal-cell width for the common Unicode ranges used by shells.
    private static func cellWidth(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        let values = scalars.map(\.value)
        if values.contains(0xFE0F)
            || values.contains(where: { (0x1F1E6 ... 0x1F1FF).contains($0) })
            || scalars.contains(where: {
                $0.properties.isEmojiPresentation || isWideScalar($0.value)
            })
        {
            return 2
        }
        return 1
    }

    private static func isWideScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100 ... 0x115F,
             0x2329 ... 0x232A,
             0x2E80 ... 0xA4CF,
             0xAC00 ... 0xD7A3,
             0xF900 ... 0xFAFF,
             0xFE10 ... 0xFE19,
             0xFE30 ... 0xFE6F,
             0xFF00 ... 0xFF60,
             0xFFE0 ... 0xFFE6,
             0x1F300 ... 0x1FAFF,
             0x20000 ... 0x3FFFD:
            true
        default:
            false
        }
    }
}
