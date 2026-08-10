import GhosttyTerminal
import UIKit

/// A growing, line-oriented snapshot of Ghostty's scrollback around the active
/// viewport. Ghostty exposes viewport reads and scroll actions separately, so
/// adjacent viewport snapshots are merged as edge selection scrolls them.
struct TerminalSelectionBuffer {
    private struct Row: Equatable {
        let text: String
        /// A visual row break created by terminal soft wrapping. It is present
        /// in the overlay layout but must not be copied as a real newline.
        let softWrapsNext: Bool
    }

    struct Integration {
        let prependedUTF16Length: Int
        let changed: Bool
    }

    struct GridPosition: Equatable {
        let line: Int
        let column: Int
    }

    struct SelectionSegment: Equatable {
        let line: Int
        let startColumn: Int
        let endColumn: Int
    }

    private var rows: [Row]
    private(set) var viewportStartLine = 0
    let viewportLineCount: Int
    let viewportColumnCount: Int

    init(
        viewportText: String,
        viewportLineCount: Int,
        viewportColumnCount: Int = .max
    ) {
        self.viewportLineCount = max(1, viewportLineCount)
        self.viewportColumnCount = max(1, viewportColumnCount)
        rows = Self.normalizedRows(
            viewportText,
            rowCount: self.viewportLineCount,
            columnCount: self.viewportColumnCount
        )
    }

    var lines: [String] { rows.map(\.text) }

    var text: String { rows.map(\.text).joined(separator: "\n") }

    var visibleUTF16Range: NSRange {
        let location = utf16Offset(ofLine: viewportStartLine)
        let endLine = min(rows.count, viewportStartLine + viewportLineCount)
        let end = utf16Offset(ofLine: endLine)
        return NSRange(location: location, length: max(0, end - location))
    }

    mutating func integrate(viewportText: String, direction: Int) -> Integration {
        let incoming = Self.normalizedRows(
            viewportText,
            rowCount: viewportLineCount,
            columnCount: viewportColumnCount
        )
        let current = currentViewport
        guard incoming != current else {
            return Integration(prependedUTF16Length: 0, changed: false)
        }

        if let existingStart = nearestExistingStart(for: incoming, direction: direction) {
            viewportStartLine = existingStart
            return Integration(prependedUTF16Length: 0, changed: true)
        }

        guard let match = Self.bestCommonRun(
            incoming,
            current,
            requestedDirection: direction
        ) else {
            return Integration(prependedUTF16Length: 0, changed: false)
        }

        // If the viewport moved by `delta`, a row at `incomingStart` now
        // overlaps the row that used to be at `currentStart`. Deriving the
        // shift from both indices avoids assuming a one-line movement at the
        // scrollback boundary, where Ghostty may satisfy only part of a larger
        // request.
        let delta = match.currentStart - match.incomingStart
        guard delta != 0,
              direction < 0 ? delta < 0 : delta > 0
        else {
            return Integration(prependedUTF16Length: 0, changed: false)
        }

        var newViewportStart = viewportStartLine + delta
        var prependedUTF16Length = 0
        if newViewportStart < 0 {
            let prefixCount = min(-newViewportStart, incoming.count)
            let prefix = Array(incoming.prefix(prefixCount))
            guard !prefix.isEmpty else {
                return Integration(prependedUTF16Length: 0, changed: false)
            }
            let inserted = prefix.map(\.text).joined(separator: "\n") + "\n"
            prependedUTF16Length = (inserted as NSString).length
            rows.insert(contentsOf: prefix, at: 0)
            newViewportStart = 0
        }

        let requiredEnd = newViewportStart + incoming.count
        if requiredEnd > rows.count {
            let suffixCount = min(requiredEnd - rows.count, incoming.count)
            rows.append(contentsOf: incoming.suffix(suffixCount))
        }
        viewportStartLine = newViewportStart
        return Integration(
            prependedUTF16Length: prependedUTF16Length,
            changed: true
        )
    }

    func utf16Offset(ofLine line: Int) -> Int {
        guard line > 0 else { return 0 }
        let capped = min(line, rows.count)
        let characterLength = rows.prefix(capped).reduce(0) {
            $0 + ($1.text as NSString).length
        }
        let separatorCount = min(capped, max(0, rows.count - 1))
        return characterLength + separatorCount
    }

    func utf16Offset(atLine line: Int, cellPosition: CGFloat) -> Int {
        guard !rows.isEmpty else { return 0 }
        let safeLine = min(max(0, line), rows.count - 1)
        let rowStart = utf16Offset(ofLine: safeLine)
        let target = max(0, cellPosition)
        var column: CGFloat = 0
        var localUTF16Offset = 0

        for character in rows[safeLine].text {
            let characterString = String(character)
            let characterLength = characterString.utf16.count
            let width = CGFloat(Self.cellWidth(of: character))
            if target < column + width {
                let trailing = target - column >= width / 2
                return rowStart + localUTF16Offset + (trailing ? characterLength : 0)
            }
            column += width
            localUTF16Offset += characterLength
        }
        return rowStart + localUTF16Offset
    }

    func gridPosition(forUTF16Offset offset: Int) -> GridPosition {
        guard !rows.isEmpty else { return GridPosition(line: 0, column: 0) }
        let clamped = min(max(0, offset), (text as NSString).length)

        for index in rows.indices {
            let start = utf16Offset(ofLine: index)
            let rowLength = (rows[index].text as NSString).length
            let end = start + rowLength
            if clamped <= end {
                return GridPosition(
                    line: index,
                    column: displayWidth(
                        of: rows[index].text as NSString,
                        utf16Length: clamped - start
                    )
                )
            }
        }

        let last = rows.count - 1
        return GridPosition(line: last, column: Self.displayWidth(of: rows[last].text))
    }

    func selectionSegments(in selectedRange: NSRange) -> [SelectionSegment] {
        let valid = normalizedSelectionRange(selectedRange)
        guard valid.length > 0 else { return [] }

        var segments: [SelectionSegment] = []
        for index in rows.indices {
            let rowStart = utf16Offset(ofLine: index)
            let rowText = rows[index].text as NSString
            let rowRange = NSRange(location: rowStart, length: rowText.length)
            let intersection = NSIntersectionRange(valid, rowRange)
            let separator = rowStart + rowText.length
            let includesSeparator = index < rows.count - 1
                && separator >= valid.location
                && separator < NSMaxRange(valid)

            guard intersection.length > 0 || includesSeparator else { continue }

            let localStart = max(0, intersection.location - rowStart)
            let localEnd = intersection.length > 0
                ? NSMaxRange(intersection) - rowStart
                : localStart
            let startColumn = displayWidth(of: rowText, utf16Length: localStart)
            var endColumn = displayWidth(of: rowText, utf16Length: localEnd)
            if includesSeparator {
                endColumn = max(endColumn, Self.displayWidth(of: rows[index].text) + 1)
            }
            if endColumn <= startColumn {
                endColumn = startColumn + 1
            }
            segments.append(SelectionSegment(
                line: index,
                startColumn: startColumn,
                endColumn: endColumn
            ))
        }
        return segments
    }

    func copyText(in selectedRange: NSRange) -> String {
        let valid = normalizedSelectionRange(selectedRange)
        guard valid.length > 0 else { return "" }

        var result = ""
        for index in rows.indices {
            let rowStart = utf16Offset(ofLine: index)
            let rowText = rows[index].text as NSString
            let rowRange = NSRange(location: rowStart, length: rowText.length)
            let intersection = NSIntersectionRange(valid, rowRange)
            if intersection.length > 0 {
                result += rowText.substring(with: NSRange(
                    location: intersection.location - rowStart,
                    length: intersection.length
                ))
            }

            let separator = rowStart + rowText.length
            if separator >= valid.location,
               separator < NSMaxRange(valid),
               index < rows.count - 1,
               !rows[index].softWrapsNext
            {
                result += "\n"
            }
        }
        return result
    }

    /// Clamp a selection to the snapshot and expand endpoints to complete
    /// grapheme clusters. UIKit reports ranges in UTF-16 units, but terminal
    /// cells contain whole graphemes; allowing an endpoint inside a surrogate
    /// pair or ZWJ emoji makes both the painted columns and copied text drift.
    func normalizedSelectionRange(_ range: NSRange) -> NSRange {
        let snapshot = text as NSString
        let valid = NSIntersectionRange(
            range,
            NSRange(location: 0, length: snapshot.length)
        )
        guard valid.length > 0 else { return valid }
        return snapshot.rangeOfComposedCharacterSequences(for: valid)
    }

    private var currentViewport: [Row] {
        let start = min(max(0, viewportStartLine), rows.count)
        let end = min(rows.count, start + viewportLineCount)
        return Array(rows[start ..< end])
    }

    private func nearestExistingStart(for incoming: [Row], direction: Int) -> Int? {
        guard incoming.count <= rows.count else { return nil }
        var candidates: [Int] = []
        for start in 0 ... (rows.count - incoming.count) {
            if Array(rows[start ..< start + incoming.count]) == incoming {
                candidates.append(start)
            }
        }
        let directional = candidates.filter {
            direction < 0 ? $0 < viewportStartLine : $0 > viewportStartLine
        }
        let expectedStart = viewportStartLine + direction
        return directional.min {
            abs($0 - expectedStart) < abs($1 - expectedStart)
        }
    }

    private static func normalizedRows(
        _ text: String,
        rowCount: Int,
        columnCount: Int
    ) -> [Row] {
        var result: [Row] = []
        for logicalLine in text.components(separatedBy: "\n") {
            if logicalLine.isEmpty {
                result.append(Row(text: "", softWrapsNext: false))
                continue
            }

            var row = ""
            var rowWidth = 0
            for character in logicalLine {
                let width = cellWidth(of: character)
                if !row.isEmpty, rowWidth + width > columnCount {
                    result.append(Row(text: row, softWrapsNext: true))
                    row = ""
                    rowWidth = 0
                }
                row.append(character)
                rowWidth += width
            }
            result.append(Row(text: row, softWrapsNext: false))
        }
        if result.count > rowCount {
            result = Array(result.prefix(rowCount))
        } else if result.count < rowCount {
            result.append(contentsOf: repeatElement(
                Row(text: "", softWrapsNext: false),
                count: rowCount - result.count
            ))
        }
        return result
    }

    private func displayWidth(of text: NSString, utf16Length: Int) -> Int {
        let safeLength = min(max(0, utf16Length), text.length)
        guard safeLength > 0 else { return 0 }

        var consumed = 0
        var width = 0
        for character in text as String {
            let characterLength = String(character).utf16.count
            guard consumed + characterLength <= safeLength else { break }
            consumed += characterLength
            width += Self.cellWidth(of: character)
        }
        return width
    }

    private static func displayWidth(of text: String) -> Int {
        text.reduce(0) { $0 + cellWidth(of: $1) }
    }

    /// Terminal-cell width for the common Unicode ranges used by shells.
    /// Grapheme clusters keep combining marks and ZWJ emoji together; CJK and
    /// emoji occupy two cells, while ambiguous-width characters remain one.
    private static func cellWidth(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        let values = scalars.map(\.value)
        if values.contains(0xFE0F)
            || values.contains(where: isRegionalIndicator)
            || scalars.contains(where: {
                $0.properties.isEmojiPresentation || isWideScalar($0.value)
            })
        {
            return 2
        }
        return 1
    }

    private static func isRegionalIndicator(_ value: UInt32) -> Bool {
        (0x1F1E6 ... 0x1F1FF).contains(value)
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

    private static func bestCommonRun(
        _ incoming: [Row],
        _ current: [Row],
        requestedDirection: Int
    ) -> (incomingStart: Int, currentStart: Int, length: Int)? {
        var candidates: [(incomingStart: Int, currentStart: Int, length: Int)] = []
        for incomingStart in incoming.indices {
            for currentStart in current.indices
            where incoming[incomingStart] == current[currentStart] {
                var length = 0
                while incomingStart + length < incoming.count,
                      currentStart + length < current.count,
                      incoming[incomingStart + length] == current[currentStart + length]
                {
                    length += 1
                }
                let delta = currentStart - incomingStart
                guard requestedDirection < 0 ? delta < 0 : delta > 0 else { continue }
                candidates.append((incomingStart, currentStart, length))
            }
        }
        guard !candidates.isEmpty else { return nil }

        // A normal N-line scroll leaves roughly rowCount-N rows overlapping.
        // Prefer such full alignments before considering a coincidental repeated
        // prompt or blank line. Near the scrollback boundary the real movement
        // may be smaller, which only increases the overlap.
        let expectedOverlap = max(
            1,
            min(incoming.count, current.count) - abs(requestedDirection)
        )
        let plausible = candidates.filter { $0.length >= expectedOverlap }
        let pool = plausible.isEmpty ? candidates : plausible

        return pool.min { lhs, rhs in
            let lhsDelta = lhs.currentStart - lhs.incomingStart
            let rhsDelta = rhs.currentStart - rhs.incomingStart
            if plausible.isEmpty, lhs.length != rhs.length {
                return lhs.length > rhs.length
            }
            let lhsDistance = abs(lhsDelta - requestedDirection)
            let rhsDistance = abs(rhsDelta - requestedDirection)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.length > rhs.length
        }
    }
}

enum TerminalSelectionEdgeScrollIntent {
    static func direction(pointY: CGFloat, in bounds: CGRect, edgeInset: CGFloat) -> Int {
        let inset = max(0, edgeInset)
        if pointY < bounds.minY + inset { return -1 }
        if pointY > bounds.maxY - inset { return 1 }
        return 0
    }
}

private final class TerminalSelectionHandleView: UIView {
    enum Endpoint {
        case start
        case end
    }

    let endpoint: Endpoint
    var selectedLineHeight: CGFloat = 14 {
        didSet { setNeedsDisplay() }
    }

    init(endpoint: Endpoint) {
        self.endpoint = endpoint
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        let stemTop: CGFloat = 12
        let stemWidth: CGFloat = 2
        let dotRadius: CGFloat = 5.5
        // Keep the two hit regions disjoint for short selections: the start
        // handle expands mostly left, while the end handle expands right.
        let x: CGFloat = endpoint == .start ? bounds.width - 8 : 8

        TTYBuildTheme.uiContent.setFill()
        UIBezierPath(
            roundedRect: CGRect(
                x: x - stemWidth / 2,
                y: stemTop,
                width: stemWidth,
                height: selectedLineHeight
            ),
            cornerRadius: stemWidth / 2
        ).fill()

        let dotY = endpoint == .start ? stemTop : stemTop + selectedLineHeight
        UIBezierPath(
            ovalIn: CGRect(
                x: x - dotRadius,
                y: dotY - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
        ).fill()
    }
}

/// A grid-native selection surface over Ghostty. Geometry is derived from the
/// emulator's pixel cell metrics instead of a second text renderer, so boxes
/// remain aligned for every font size and while the viewport scrolls.
@MainActor
final class TerminalSelectionOverlay: UIView, UIGestureRecognizerDelegate {
    var onScrollRequest: ((_ lines: Int, _ completion: @escaping (String?) -> Void) -> Void)?
    var onFinish: (() -> Void)?

    private var buffer: TerminalSelectionBuffer
    private let sourcePoint: CGPoint
    private let initialAnchorText: String?
    private let viewport: InMemoryTerminalViewport
    private let viewportSize: CGSize
    private let displayScale: CGFloat
    private let contentInsets = TerminalCanvasLayout.contentInsets

    private let selectionLayer = CAShapeLayer()
    private let startHandleView = TerminalSelectionHandleView(endpoint: .start)
    private let endHandleView = TerminalSelectionHandleView(endpoint: .end)
    private lazy var editMenuInteraction = UIEditMenuInteraction(delegate: self)
    private lazy var selectionTap = UITapGestureRecognizer(
        target: self,
        action: #selector(handleSelectionTap(_:))
    )
    private lazy var viewportPan = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleViewportPan(_:))
    )
    private lazy var startHandlePan = UIPanGestureRecognizer(
        target: self,
        action: #selector(dragStartHandle(_:))
    )
    private lazy var endHandlePan = UIPanGestureRecognizer(
        target: self,
        action: #selector(dragEndHandle(_:))
    )

    private var selectedRange = NSRange(location: 0, length: 0)
    private var activeEndpoint: SelectionEndpoint?
    private var activeEdgeColumn = 0
    private var edgeDirection = 0
    private var edgeTimer: Timer?
    private var scrollRequestInFlight = false
    private var queuedViewportScrollLines = 0
    private var scrollRemainder: CGFloat = 0
    private var wantsMenuAfterScroll = false
    private var hasActivated = false
    private var hasFinished = false

    private enum SelectionEndpoint {
        case start
        case end
    }

    init(
        viewportText: String,
        anchorRange: NSRange?,
        sourcePoint: CGPoint,
        viewport: InMemoryTerminalViewport,
        viewportSize: CGSize,
        displayScale: CGFloat
    ) {
        buffer = TerminalSelectionBuffer(
            viewportText: viewportText,
            viewportLineCount: Int(max(1, viewport.rows)),
            viewportColumnCount: Int(max(1, viewport.columns))
        )
        self.sourcePoint = sourcePoint
        self.viewport = viewport
        self.viewportSize = viewportSize
        self.displayScale = max(1, displayScale)

        let source = viewportText as NSString
        if let anchorRange,
           anchorRange.location >= 0,
           anchorRange.length > 0,
           NSMaxRange(anchorRange) <= source.length
        {
            initialAnchorText = source.substring(with: anchorRange)
        } else {
            initialAnchorText = nil
        }
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func activate() {
        guard !hasActivated else { return }
        hasActivated = true
        setNeedsLayout()
        layoutIfNeeded()
        applySelection(validatedInitialRange())
        DispatchQueue.main.async { [weak self] in self?.presentSystemEditMenu() }
    }

    func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        stopEdgeScrolling()
        queuedViewportScrollLines = 0
        editMenuInteraction.dismissMenu()
        onFinish?()
    }

    func refreshViewport(_ viewportText: String, direction: Int = 1) {
        guard hasActivated, !hasFinished,
              activeEndpoint == nil,
              viewportPan.state == .possible,
              !scrollRequestInFlight
        else { return }

        var selected = selectedRange
        let integration = buffer.integrate(viewportText: viewportText, direction: direction)
        guard integration.changed else { return }
        if integration.prependedUTF16Length > 0 {
            selected.location += integration.prependedUTF16Length
        }
        applySelection(selected)
    }

    private func copySelection() {
        let copied = buffer.copyText(in: selectedRange)
        guard !copied.isEmpty else { return }
        UIPasteboard.general.string = copied
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(notification: .announcement, argument: "Copied")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        selectionLayer.frame = bounds
        refreshSelectionRendering()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopEdgeScrolling() }
    }

    private var cellWidth: CGFloat {
        if viewport.cellWidthPixels > 0 {
            return CGFloat(viewport.cellWidthPixels) / displayScale
        }
        let available = max(1, viewportSize.width - contentInsets.left - contentInsets.right)
        return available / CGFloat(max(1, viewport.columns))
    }

    private var cellHeight: CGFloat {
        if viewport.cellHeightPixels > 0 {
            return CGFloat(viewport.cellHeightPixels) / displayScale
        }
        let available = max(1, viewportSize.height - contentInsets.top - contentInsets.bottom)
        return available / CGFloat(max(1, viewport.rows))
    }

    private func configure() {
        accessibilityIdentifier = "terminal.selectionOverlay"
        accessibilityLabel = "Terminal text selection"
        backgroundColor = .clear
        clipsToBounds = true

        selectionLayer.fillColor = TTYBuildTheme.uiContent.withAlphaComponent(0.28).cgColor
        selectionLayer.contentsScale = displayScale
        layer.addSublayer(selectionLayer)

        viewportPan.minimumNumberOfTouches = 1
        viewportPan.maximumNumberOfTouches = 1
        viewportPan.delegate = self
        addGestureRecognizer(viewportPan)

        for (handle, recognizer) in [
            (startHandleView, startHandlePan),
            (endHandleView, endHandlePan),
        ] {
            handle.addGestureRecognizer(recognizer)
            addSubview(handle)
        }
        startHandleView.accessibilityIdentifier = "terminal.selectionStartHandle"
        startHandleView.accessibilityLabel = "Selection start"
        startHandleView.isAccessibilityElement = true
        endHandleView.accessibilityIdentifier = "terminal.selectionEndHandle"
        endHandleView.accessibilityLabel = "Selection end"
        endHandleView.isAccessibilityElement = true

        addInteraction(editMenuInteraction)
        selectionTap.cancelsTouchesInView = false
        selectionTap.delegate = self
        selectionTap.require(toFail: viewportPan)
        selectionTap.require(toFail: startHandlePan)
        selectionTap.require(toFail: endHandlePan)
        addGestureRecognizer(selectionTap)
    }

    private func validatedInitialRange() -> NSRange {
        let length = (buffer.text as NSString).length
        if let initialAnchorText,
           let preferred = preferredRange(of: initialAnchorText, near: sourcePoint),
           preferred.length > 0
        {
            return preferred
        }
        if let fallback = wordRange(at: sourcePoint), fallback.length > 0 {
            return fallback
        }
        return NSRange(location: 0, length: min(length, 1))
    }

    private func preferredRange(of anchor: String, near point: CGPoint) -> NSRange? {
        guard !anchor.isEmpty, !buffer.lines.isEmpty else { return nil }
        let row = visibleLine(at: point.y)
        let line = buffer.lines[row] as NSString
        let anchorLength = (anchor as NSString).length
        guard anchorLength > 0, anchorLength <= line.length else { return nil }

        let localTouch = characterOffset(at: point) - buffer.utf16Offset(ofLine: row)
        var candidates: [NSRange] = []
        var search = NSRange(location: 0, length: line.length)
        while search.length >= anchorLength {
            let match = line.range(of: anchor, options: [], range: search)
            guard match.location != NSNotFound else { break }
            candidates.append(match)
            let next = NSMaxRange(match)
            search = NSRange(location: next, length: line.length - next)
        }
        guard let nearest = candidates.min(by: {
            abs($0.location - localTouch) < abs($1.location - localTouch)
        }) else { return nil }
        return NSRange(
            location: buffer.utf16Offset(ofLine: row) + nearest.location,
            length: nearest.length
        )
    }

    private func wordRange(at point: CGPoint) -> NSRange? {
        guard !buffer.lines.isEmpty else { return nil }
        let row = visibleLine(at: point.y)
        let lineString = buffer.lines[row]
        let line = lineString as NSString
        guard line.length > 0 else { return nil }

        let rowStart = buffer.utf16Offset(ofLine: row)
        let touchedOffset = min(
            max(0, characterOffset(at: point) - rowStart),
            line.length - 1
        )
        let whitespace = CharacterSet.whitespacesAndNewlines

        var clusters: [(range: NSRange, isWhitespace: Bool)] = []
        lineString.enumerateSubstrings(
            in: lineString.startIndex ..< lineString.endIndex,
            options: .byComposedCharacterSequences
        ) { substring, range, _, _ in
            guard let substring else { return }
            clusters.append((
                range: NSRange(range, in: lineString),
                isWhitespace: substring.unicodeScalars.allSatisfy(whitespace.contains)
            ))
        }
        guard !clusters.isEmpty else { return nil }

        var clusterIndex = clusters.firstIndex {
            NSLocationInRange(touchedOffset, $0.range)
        } ?? (clusters.count - 1)
        if clusters[clusterIndex].isWhitespace {
            let nonWhitespace = clusters.indices.filter { !clusters[$0].isWhitespace }
            guard let nearest = nonWhitespace.min(by: {
                abs(clusters[$0].range.location - touchedOffset)
                    < abs(clusters[$1].range.location - touchedOffset)
            }) else { return nil }
            clusterIndex = nearest
        }

        var lower = clusterIndex
        var upper = clusterIndex
        while lower > clusters.startIndex, !clusters[lower - 1].isWhitespace { lower -= 1 }
        while upper + 1 < clusters.endIndex, !clusters[upper + 1].isWhitespace { upper += 1 }
        let localRange = NSUnionRange(clusters[lower].range, clusters[upper].range)
        return NSRange(location: rowStart + localRange.location, length: localRange.length)
    }

    private func applySelection(_ proposedRange: NSRange) {
        selectedRange = buffer.normalizedSelectionRange(proposedRange)
        refreshSelectionRendering()
    }

    @objc private func dragStartHandle(_ gesture: UIPanGestureRecognizer) {
        dragHandle(gesture, endpoint: .start)
    }

    @objc private func dragEndHandle(_ gesture: UIPanGestureRecognizer) {
        dragHandle(gesture, endpoint: .end)
    }

    private func dragHandle(
        _ gesture: UIPanGestureRecognizer,
        endpoint: SelectionEndpoint
    ) {
        switch gesture.state {
        case .began, .changed:
            if gesture.state == .began { editMenuInteraction.dismissMenu() }
            activeEndpoint = endpoint
            let point = gesture.location(in: self)
            activeEdgeColumn = max(
                0,
                Int((point.x - contentInsets.left) / max(1, cellWidth))
            )
            moveSelectionEndpoint(endpoint, to: point)

            let edge = min(78, bounds.height * 0.16)
            let direction = TerminalSelectionEdgeScrollIntent.direction(
                pointY: point.y,
                in: bounds,
                edgeInset: edge
            )
            if direction != 0 {
                startEdgeScrolling(direction: direction)
            } else {
                stopEdgeScrolling()
            }

        case .ended, .cancelled, .failed:
            stopEdgeScrolling()
            activeEndpoint = nil
            activeEdgeColumn = 0
            if gesture.state == .ended {
                wantsMenuAfterScroll = true
                presentMenuIfScrollSettled()
            }
        default:
            break
        }
    }

    private func moveSelectionEndpoint(
        _ endpoint: SelectionEndpoint,
        to point: CGPoint
    ) {
        let offset = characterOffset(at: point)
        let length = (buffer.text as NSString).length
        let current = selectedRange
        guard length > 0, current.length > 0 else { return }

        switch endpoint {
        case .start:
            let end = NSMaxRange(current)
            let start = min(max(0, offset), max(0, end - 1))
            selectedRange = buffer.normalizedSelectionRange(
                NSRange(location: start, length: end - start)
            )
        case .end:
            let end = max(current.location + 1, min(offset, length))
            selectedRange = buffer.normalizedSelectionRange(
                NSRange(location: current.location, length: end - current.location)
            )
        }
        refreshSelectionRendering()
    }

    @objc private func handleViewportPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            editMenuInteraction.dismissMenu()
            scrollRemainder = 0
            wantsMenuAfterScroll = false
        case .changed:
            let delta = gesture.translation(in: self).y
            gesture.setTranslation(.zero, in: self)
            scrollRemainder += delta
            let lines = Int(scrollRemainder / max(1, cellHeight))
            guard lines != 0 else { return }
            scrollRemainder -= CGFloat(lines) * cellHeight
            enqueueViewportScroll(lines: -lines)
        case .ended:
            scrollRemainder = 0
            wantsMenuAfterScroll = true
            presentMenuIfScrollSettled()
        case .cancelled, .failed:
            scrollRemainder = 0
            wantsMenuAfterScroll = true
            presentMenuIfScrollSettled()
        default:
            break
        }
    }

    private func enqueueViewportScroll(lines: Int) {
        guard lines != 0 else { return }
        queuedViewportScrollLines += lines
        drainViewportScrollQueue()
    }

    private func drainViewportScrollQueue() {
        guard !scrollRequestInFlight, queuedViewportScrollLines != 0 else {
            presentMenuIfScrollSettled()
            return
        }
        let sign = queuedViewportScrollLines < 0 ? -1 : 1
        let chunk = sign * min(abs(queuedViewportScrollLines), 6)
        queuedViewportScrollLines -= chunk
        performScrollRequest(lines: chunk, endpoint: nil, column: 0)
    }

    private func characterOffset(at point: CGPoint) -> Int {
        guard !buffer.lines.isEmpty else { return 0 }
        let row = visibleLine(at: point.y)
        let cellPosition = (point.x - contentInsets.left) / max(1, cellWidth)
        return buffer.utf16Offset(atLine: row, cellPosition: cellPosition)
    }

    private func visibleLine(at y: CGFloat) -> Int {
        let localY = y - contentInsets.top
        let visibleRow = Int(floor(localY / max(1, cellHeight)))
        return min(
            max(0, buffer.viewportStartLine + visibleRow),
            max(0, buffer.lines.count - 1)
        )
    }

    private func refreshSelectionRendering() {
        guard selectedRange.length > 0,
              NSMaxRange(selectedRange) <= (buffer.text as NSString).length
        else {
            selectionLayer.path = nil
            startHandleView.isHidden = true
            endHandleView.isHidden = true
            return
        }

        let path = UIBezierPath()
        let visibleStart = buffer.viewportStartLine
        let visibleEnd = visibleStart + Int(max(1, viewport.rows))
        let gridMaxX = min(
            bounds.maxX - contentInsets.right,
            contentInsets.left + CGFloat(max(1, viewport.columns)) * cellWidth
        )

        for segment in buffer.selectionSegments(in: selectedRange)
        where segment.line >= visibleStart && segment.line < visibleEnd {
            let row = segment.line - visibleStart
            let x = alignedToDisplayPixel(
                contentInsets.left + CGFloat(segment.startColumn) * cellWidth
            )
            let endX = alignedToDisplayPixel(min(
                gridMaxX,
                contentInsets.left + CGFloat(segment.endColumn) * cellWidth
            ))
            let y = alignedToDisplayPixel(contentInsets.top + CGFloat(row) * cellHeight)
            let bottom = alignedToDisplayPixel(
                contentInsets.top + CGFloat(row + 1) * cellHeight
            )
            let rect = CGRect(
                x: x,
                y: y,
                width: max(cellWidth * 0.5, endX - x),
                height: max(1 / displayScale, bottom - y)
            ).intersection(bounds)
            if !rect.isNull, !rect.isEmpty {
                path.append(UIBezierPath(roundedRect: rect, cornerRadius: 2))
            }
        }
        selectionLayer.path = path.cgPath

        layoutHandle(
            startHandleView,
            position: buffer.gridPosition(forUTF16Offset: selectedRange.location)
        )
        layoutHandle(
            endHandleView,
            position: buffer.gridPosition(forUTF16Offset: NSMaxRange(selectedRange))
        )
        bringSubviewToFront(startHandleView)
        bringSubviewToFront(endHandleView)
    }

    private func layoutHandle(
        _ handle: TerminalSelectionHandleView,
        position: TerminalSelectionBuffer.GridPosition
    ) {
        let visibleRow = position.line - buffer.viewportStartLine
        let lineTop = contentInsets.top
            + CGFloat(visibleRow) * cellHeight
        guard visibleRow >= -1,
              visibleRow <= Int(max(1, viewport.rows)),
              lineTop + cellHeight >= bounds.minY,
              lineTop <= bounds.maxY
        else {
            handle.isHidden = true
            return
        }

        let x = alignedToDisplayPixel(
            contentInsets.left + CGFloat(position.column) * cellWidth
        )
        let width: CGFloat = 48
        let height = max(48, cellHeight + 24)
        handle.selectedLineHeight = cellHeight
        handle.frame = CGRect(
            x: handle.endpoint == .start ? x - width + 8 : x - 8,
            y: lineTop - 12,
            width: width,
            height: height
        )
        handle.isHidden = false
    }

    @objc private func handleSelectionTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if selectionLayer.path?.contains(point) == true {
            DispatchQueue.main.async { [weak self] in
                self?.presentSystemEditMenu(sourcePoint: point)
            }
        } else {
            finish()
        }
    }

    private func presentSystemEditMenu(sourcePoint: CGPoint? = nil) {
        guard window != nil, selectedRange.length > 0, !hasFinished else { return }
        let targetRect = selectionMenuTargetRect
        let target = sourcePoint ?? CGPoint(x: targetRect.midX, y: targetRect.midY)
        editMenuInteraction.presentEditMenu(
            with: UIEditMenuConfiguration(identifier: nil, sourcePoint: target)
        )
    }

    private var selectionMenuTargetRect: CGRect {
        guard let path = selectionLayer.path else {
            return CGRect(origin: sourcePoint, size: CGSize(width: 1, height: 1))
        }
        let visible = path.boundingBoxOfPath.intersection(bounds)
        guard !visible.isNull, !visible.isEmpty else {
            return CGRect(origin: sourcePoint, size: CGSize(width: 1, height: 1))
        }
        return visible
    }

    private func startEdgeScrolling(direction: Int) {
        guard edgeDirection != direction else { return }
        stopEdgeScrolling()
        edgeDirection = direction
        requestNextEdgeScroll()

        let timer = Timer(timeInterval: 0.13, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestNextEdgeScroll() }
        }
        edgeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopEdgeScrolling() {
        edgeTimer?.invalidate()
        edgeTimer = nil
        edgeDirection = 0
    }

    private func requestNextEdgeScroll() {
        guard edgeDirection != 0,
              !scrollRequestInFlight,
              queuedViewportScrollLines == 0
        else { return }
        performScrollRequest(
            lines: edgeDirection,
            endpoint: activeEndpoint,
            column: activeEdgeColumn
        )
    }

    private func performScrollRequest(
        lines: Int,
        endpoint: SelectionEndpoint?,
        column: Int
    ) {
        guard lines != 0, let onScrollRequest else {
            stopEdgeScrolling()
            return
        }

        scrollRequestInFlight = true

        onScrollRequest(lines) { [weak self] viewportText in
            guard let self else { return }
            scrollRequestInFlight = false

            guard let viewportText else {
                stopEdgeScrolling()
                refreshSelectionRendering()
                drainViewportScrollQueue()
                return
            }

            var selected = selectedRange
            let integration = buffer.integrate(viewportText: viewportText, direction: lines)
            if integration.prependedUTF16Length > 0 {
                selected.location += integration.prependedUTF16Length
            }

            if integration.changed {
                let firstVisibleLine = min(
                    buffer.viewportStartLine,
                    max(0, buffer.lines.count - 1)
                )
                let lastVisibleLine = min(
                    buffer.viewportStartLine + Int(max(1, viewport.rows)) - 1,
                    max(0, buffer.lines.count - 1)
                )
                let edgeLine = lines < 0 ? firstVisibleLine : lastVisibleLine
                let edge = buffer.utf16Offset(
                    atLine: edgeLine,
                    cellPosition: CGFloat(column)
                )

                switch endpoint {
                case .start:
                    let end = NSMaxRange(selected)
                    let start = min(max(0, edge), max(0, end - 1))
                    selected = NSRange(location: start, length: end - start)
                case .end:
                    let textLength = (buffer.text as NSString).length
                    let end = max(selected.location + 1, min(edge, textLength))
                    selected.length = end - selected.location
                case nil:
                    break
                }
            }

            applySelection(selected)
            drainViewportScrollQueue()
            presentMenuIfScrollSettled()
        }
    }

    private func presentMenuIfScrollSettled() {
        guard wantsMenuAfterScroll,
              !scrollRequestInFlight,
              queuedViewportScrollLines == 0,
              activeEndpoint == nil,
              viewportPan.state != .began,
              viewportPan.state != .changed
        else { return }
        wantsMenuAfterScroll = false
        DispatchQueue.main.async { [weak self] in self?.presentSystemEditMenu() }
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        selectionMenuTargetRect
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        UIMenu(children: [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) {
                [weak self] _ in
                self?.copySelection()
            },
        ])
    }

    private func alignedToDisplayPixel(_ value: CGFloat) -> CGFloat {
        (value * displayScale).rounded() / displayScale
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === viewportPan else { return true }
        let velocity = viewportPan.velocity(in: self)
        return abs(velocity.y) > abs(velocity.x) * 1.35
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === selectionTap || gestureRecognizer === viewportPan
        else { return true }
        guard let touchedView = touch.view else { return true }
        return !touchedView.isDescendant(of: startHandleView)
            && !touchedView.isDescendant(of: endHandleView)
    }
}

extension TerminalSelectionOverlay: @preconcurrency UIEditMenuInteractionDelegate {}
