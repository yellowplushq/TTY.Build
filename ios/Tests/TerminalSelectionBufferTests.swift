import XCTest
@testable import TTYBuild

final class TerminalSelectionBufferTests: XCTestCase {
    func testPrependsAnOlderViewportAndShiftsTheExistingSelection() {
        var buffer = TerminalSelectionBuffer(
            viewportText: "bravo\ncharlie\ndelta",
            viewportLineCount: 3
        )

        let integration = buffer.integrate(
            viewportText: "alpha\nbravo\ncharlie",
            direction: -1
        )

        XCTAssertTrue(integration.changed)
        XCTAssertEqual(integration.prependedUTF16Length, 6)
        XCTAssertEqual(buffer.text, "alpha\nbravo\ncharlie\ndelta")
        XCTAssertEqual(buffer.viewportStartLine, 0)
        XCTAssertEqual(buffer.visibleUTF16Range, NSRange(location: 0, length: 20))
    }

    func testMovesBackToAnAlreadyBufferedNewerViewportWithoutDuplicatingLines() {
        var buffer = TerminalSelectionBuffer(
            viewportText: "bravo\ncharlie\ndelta",
            viewportLineCount: 3
        )
        _ = buffer.integrate(
            viewportText: "alpha\nbravo\ncharlie",
            direction: -1
        )

        let integration = buffer.integrate(
            viewportText: "bravo\ncharlie\ndelta",
            direction: 1
        )

        XCTAssertTrue(integration.changed)
        XCTAssertEqual(integration.prependedUTF16Length, 0)
        XCTAssertEqual(buffer.text, "alpha\nbravo\ncharlie\ndelta")
        XCTAssertEqual(buffer.viewportStartLine, 1)
    }

    func testAccumulatesSelectionTextAcrossMoreThanOneScreen() {
        var buffer = TerminalSelectionBuffer(
            viewportText: "charlie\ndelta\necho",
            viewportLineCount: 3
        )

        let first = buffer.integrate(
            viewportText: "bravo\ncharlie\ndelta",
            direction: -1
        )
        let second = buffer.integrate(
            viewportText: "alpha\nbravo\ncharlie",
            direction: -1
        )

        XCTAssertEqual(first.prependedUTF16Length, 6)
        XCTAssertEqual(second.prependedUTF16Length, 6)
        XCTAssertEqual(buffer.text, "alpha\nbravo\ncharlie\ndelta\necho")
        XCTAssertEqual(buffer.lines.count, 5)
        XCTAssertEqual(buffer.visibleUTF16Range, NSRange(location: 0, length: 20))
    }

    func testAppendsANewerViewport() {
        var buffer = TerminalSelectionBuffer(
            viewportText: "alpha\nbravo\ncharlie",
            viewportLineCount: 3
        )

        let integration = buffer.integrate(
            viewportText: "bravo\ncharlie\ndelta",
            direction: 1
        )

        XCTAssertTrue(integration.changed)
        XCTAssertEqual(buffer.text, "alpha\nbravo\ncharlie\ndelta")
        XCTAssertEqual(buffer.viewportStartLine, 1)
        XCTAssertEqual(
            buffer.visibleUTF16Range,
            NSRange(location: 6, length: 19)
        )
    }

    func testSoftWrappedRowsMatchTheTerminalGridWithoutAddingCopiedNewlines() {
        let buffer = TerminalSelectionBuffer(
            viewportText: "abcdefghij\nnext",
            viewportLineCount: 4,
            viewportColumnCount: 5
        )

        XCTAssertEqual(buffer.lines, ["abcde", "fghij", "next", ""])
        XCTAssertEqual(
            buffer.copyText(in: NSRange(location: 0, length: 16)),
            "abcdefghij\nnext"
        )
    }

    func testOlderViewportMergesThroughSharedContentDespiteDifferentTrailingRows() {
        var buffer = TerminalSelectionBuffer(
            viewportText: "169\n170\n171\nprompt",
            viewportLineCount: 4
        )

        let integration = buffer.integrate(
            viewportText: "166\n167\n168\n169\n170\n171",
            direction: -1
        )

        XCTAssertTrue(integration.changed)
        XCTAssertEqual(
            buffer.lines,
            ["166", "167", "168", "169", "170", "171", "prompt"]
        )
    }

    func testLargeUpwardRequestUsesActualPartialMovementAtScrollbackTop() {
        var buffer = TerminalSelectionBuffer(
            viewportText: "alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot",
            viewportLineCount: 6
        )

        let integration = buffer.integrate(
            viewportText: "older one\nolder two\nalpha\nbravo\ncharlie\ndelta",
            direction: -6
        )

        XCTAssertTrue(integration.changed)
        XCTAssertEqual(buffer.viewportStartLine, 0)
        XCTAssertEqual(
            buffer.lines,
            [
                "older one", "older two", "alpha", "bravo",
                "charlie", "delta", "echo", "foxtrot",
            ]
        )
    }

    func testRepeatedRowsDoNotOverrideTheFullViewportAlignment() {
        var buffer = TerminalSelectionBuffer(
            viewportText: "prompt\none\nprompt\ntwo\nprompt\nthree",
            viewportLineCount: 6
        )

        let integration = buffer.integrate(
            viewportText: "older one\nolder two\nprompt\none\nprompt\ntwo",
            direction: -2
        )

        XCTAssertTrue(integration.changed)
        XCTAssertEqual(
            buffer.lines,
            [
                "older one", "older two", "prompt", "one",
                "prompt", "two", "prompt", "three",
            ]
        )
    }

    func testSelectionSegmentsUseTerminalCellsForWideCharacters() {
        let buffer = TerminalSelectionBuffer(
            viewportText: "a你b",
            viewportLineCount: 1,
            viewportColumnCount: 4
        )

        XCTAssertEqual(
            buffer.selectionSegments(in: NSRange(location: 1, length: 1)),
            [.init(line: 0, startColumn: 1, endColumn: 3)]
        )
        XCTAssertEqual(
            buffer.gridPosition(forUTF16Offset: 2),
            .init(line: 0, column: 3)
        )
    }

    func testSoftWrappingCountsWideCharactersByCells() {
        let buffer = TerminalSelectionBuffer(
            viewportText: "ab你c",
            viewportLineCount: 2,
            viewportColumnCount: 4
        )

        XCTAssertEqual(buffer.lines, ["ab你", "c"])
        XCTAssertEqual(
            buffer.copyText(in: NSRange(location: 0, length: 5)),
            "ab你c"
        )
    }

    func testEmojiSequencesUseGhosttyCompatibleTwoCellWidths() {
        let buffer = TerminalSelectionBuffer(
            viewportText: "a☁️🇺🇸1️⃣b",
            viewportLineCount: 1,
            viewportColumnCount: 8
        )

        XCTAssertEqual(
            buffer.selectionSegments(in: NSRange(location: 1, length: 2)),
            [.init(line: 0, startColumn: 1, endColumn: 3)]
        )
        XCTAssertEqual(
            buffer.selectionSegments(in: NSRange(location: 3, length: 4)),
            [.init(line: 0, startColumn: 3, endColumn: 5)]
        )
        XCTAssertEqual(
            buffer.selectionSegments(in: NSRange(location: 7, length: 3)),
            [.init(line: 0, startColumn: 5, endColumn: 7)]
        )
        XCTAssertEqual(
            buffer.gridPosition(forUTF16Offset: 11),
            .init(line: 0, column: 8)
        )
    }

    func testUTF16OffsetsInsideEmojiSnapToTheWholeGrapheme() {
        let buffer = TerminalSelectionBuffer(
            viewportText: "a😀b",
            viewportLineCount: 1,
            viewportColumnCount: 4
        )

        XCTAssertEqual(
            buffer.normalizedSelectionRange(NSRange(location: 2, length: 1)),
            NSRange(location: 1, length: 2)
        )
        XCTAssertEqual(
            buffer.copyText(in: NSRange(location: 2, length: 1)),
            "😀"
        )
        XCTAssertEqual(
            buffer.gridPosition(forUTF16Offset: 2),
            .init(line: 0, column: 1)
        )
    }
}

final class TerminalSelectionEdgeScrollIntentTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 390, height: 420)

    func testDraggingIntoTheKeyboardRegionScrollsTowardNewerContent() {
        XCTAssertEqual(
            TerminalSelectionEdgeScrollIntent.direction(
                pointY: 500,
                in: bounds,
                edgeInset: 64
            ),
            1
        )
    }

    func testTopEdgeAndMiddleDirections() {
        XCTAssertEqual(
            TerminalSelectionEdgeScrollIntent.direction(
                pointY: 20,
                in: bounds,
                edgeInset: 64
            ),
            -1
        )
        XCTAssertEqual(
            TerminalSelectionEdgeScrollIntent.direction(
                pointY: 210,
                in: bounds,
                edgeInset: 64
            ),
            0
        )
    }
}

final class TerminalPagingIntentTests: XCTestCase {
    func testRequiresAnUnambiguouslyHorizontalGesture() {
        XCTAssertTrue(TerminalPagingIntent.shouldBegin(
            velocity: CGPoint(x: -800, y: 200),
            currentIndex: 0,
            pageCount: 3,
            selectionActive: false
        ))
        XCTAssertFalse(TerminalPagingIntent.shouldBegin(
            velocity: CGPoint(x: -350, y: 250),
            currentIndex: 0,
            pageCount: 3,
            selectionActive: false
        ))
    }

    func testDoesNotPageDuringSelectionOrWithOnlyOneTerminal() {
        XCTAssertFalse(TerminalPagingIntent.shouldBegin(
            velocity: CGPoint(x: -800, y: 0),
            currentIndex: 0,
            pageCount: 3,
            selectionActive: true
        ))
        XCTAssertFalse(TerminalPagingIntent.shouldBegin(
            velocity: CGPoint(x: -800, y: 0),
            currentIndex: 0,
            pageCount: 1,
            selectionActive: false
        ))
    }

    func testDoesNotRubberBandPastEitherBoundary() {
        XCTAssertFalse(TerminalPagingIntent.shouldBegin(
            velocity: CGPoint(x: 800, y: 0),
            currentIndex: 0,
            pageCount: 3,
            selectionActive: false
        ))
        XCTAssertFalse(TerminalPagingIntent.shouldBegin(
            velocity: CGPoint(x: -800, y: 0),
            currentIndex: 2,
            pageCount: 3,
            selectionActive: false
        ))
    }
}
