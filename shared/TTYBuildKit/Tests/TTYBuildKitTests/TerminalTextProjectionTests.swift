import Foundation
@testable import TTYBuildKit
import XCTest

final class TerminalTextProjectionTests: XCTestCase {
    func testPlainTextAndNewlines() {
        var projection = TerminalTextProjection(cols: 80, rows: 24)
        projection.feed(Data("first\nsecond".utf8))

        XCTAssertEqual(projection.snapshot.text, "first\nsecond")
    }

    func testANSIStylesAreRemovedButTextRemains() {
        var projection = TerminalTextProjection(cols: 80, rows: 24)
        projection.feed(Data("normal \u{1B}[31mred\u{1B}[0m text".utf8))

        XCTAssertEqual(projection.snapshot.text, "normal red text")
    }

    func testANSIIndexedAndTrueColorStylesBecomeRuns() {
        var projection = TerminalTextProjection(cols: 80, rows: 24)
        projection.feed(Data(
            "plain \u{1B}[1;31mred\u{1B}[0m \u{1B}[38;2;12;34;56mRGB\u{1B}[0m".utf8
        ))

        XCTAssertEqual(projection.snapshot.lines[0].runs, [
            .init(text: "plain ", style: .init()),
            .init(text: "red", style: .init(foreground: .indexed(1), bold: true)),
            .init(text: " ", style: .init()),
            .init(
                text: "RGB",
                style: .init(foreground: .rgb(red: 12, green: 34, blue: 56))
            ),
        ])
    }

    func testBackgroundUnderlineAndInverseStylesAreTracked() {
        var projection = TerminalTextProjection(cols: 80, rows: 24)
        projection.feed(Data("\u{1B}[4;7;48;5;25mstyled\u{1B}[0m".utf8))

        XCTAssertEqual(
            projection.snapshot.lines[0].runs,
            [.init(
                text: "styled",
                style: .init(
                    background: .indexed(25),
                    underlined: true,
                    inverted: true
                )
            )]
        )
    }

    func testUTF8AndCSISequencesCanCrossChunks() {
        var projection = TerminalTextProjection(cols: 80, rows: 24)
        let bytes = Array("你 \u{1B}[32m好\u{1B}[0m".utf8)
        for byte in bytes {
            projection.feed(Data([byte]))
        }

        XCTAssertEqual(projection.snapshot.text, "你 好")
    }

    func testCharacterSetDesignatorsDoNotLeakTheirFinalBytes() {
        var projection = TerminalTextProjection(cols: 80, rows: 24)
        projection.feed(Data("left \u{1B}(Bright \u{1B})0end".utf8))

        XCTAssertEqual(projection.snapshot.text, "left right end")
    }

    func testCarriageReturnOverwritesProgressLine() {
        var projection = TerminalTextProjection(cols: 80, rows: 24)
        projection.feed(Data("progress 10%\rprogress 90%".utf8))

        XCTAssertEqual(projection.snapshot.text, "progress 90%")
    }

    func testEraseLineClearsStaleSuffix() {
        var projection = TerminalTextProjection(cols: 80, rows: 24)
        projection.feed(Data("a very long value\rshort\u{1B}[K".utf8))

        XCTAssertEqual(projection.snapshot.text, "short")
    }

    func testCursorAddressedOutputUpdatesGrid() {
        var projection = TerminalTextProjection(cols: 20, rows: 4)
        projection.feed(Data("one\ntwo\nthree\u{1B}[2;1HSECOND".utf8))

        XCTAssertEqual(projection.snapshot.text, "one\nSECOND\nthree")
    }

    func testSoftWrappedRowsRemainSeparateGridRows() {
        var projection = TerminalTextProjection(cols: 5, rows: 4)
        projection.feed(Data("abcdefgh".utf8))

        XCTAssertEqual(projection.snapshot.lines.map(\.text), ["abcde", "fgh"])
    }

    func testHardNewlineDoesNotMergeRows() {
        var projection = TerminalTextProjection(cols: 5, rows: 4)
        projection.feed(Data("abcde\nfg".utf8))

        XCTAssertEqual(projection.snapshot.lines.map(\.text), ["abcde", "fg"])
    }

    func testWideCharactersOccupyTwoCells() {
        var projection = TerminalTextProjection(cols: 4, rows: 4)
        projection.feed(Data("ab你c".utf8))

        XCTAssertEqual(projection.snapshot.lines.map(\.text), ["ab你", "c"])
    }

    func testSnapshotReportsFixedGridDimensions() {
        let projection = TerminalTextProjection(cols: 48, rows: 21)

        XCTAssertEqual(projection.snapshot.columns, 48)
        XCTAssertEqual(projection.snapshot.rows, 21)
    }

    func testResizeClipsRowsAndUpdatesCursorCoordinateSpace() {
        var projection = TerminalTextProjection(cols: 8, rows: 4)
        projection.feed(Data("12345678\nabcdefgh".utf8))
        let lineIDs = projection.snapshot.lines.map(\.id)

        projection.resize(cols: 5, rows: 3)
        projection.feed(Data("\u{1B}[2;5HZ".utf8))

        XCTAssertEqual(projection.snapshot.columns, 5)
        XCTAssertEqual(projection.snapshot.rows, 3)
        XCTAssertEqual(projection.snapshot.lines.map(\.text), ["12345", "abcdZ"])
        XCTAssertEqual(projection.snapshot.lines.map(\.id), lineIDs)
    }

    func testResizeGrowthDoesNotTurnScrollbackBackIntoWritableScreenRows() {
        var projection = TerminalTextProjection(cols: 8, rows: 4)
        projection.feed(Data("one\ntwo\nthree\nfour".utf8))
        let scrollbackIDs = Array(projection.snapshot.lines.prefix(2).map(\.id))

        projection.resize(cols: 5, rows: 2)
        projection.feed(Data("\u{1B}[1;1H\u{1B}[2Jsmall\nmode".utf8))
        projection.resize(cols: 8, rows: 4)
        projection.feed(Data("\u{1B}[1;1H\u{1B}[2Jwide-1\nwide-2\nwide-3\nwide-4".utf8))

        XCTAssertEqual(
            projection.snapshot.lines.map(\.text),
            ["one", "two", "wide-1", "wide-2", "wide-3", "wide-4"]
        )
        XCTAssertEqual(
            Array(projection.snapshot.lines.prefix(2).map(\.id)),
            scrollbackIDs
        )
    }

    func testViewportLinesContainOnlyTheCurrentTTYScreen() {
        var projection = TerminalTextProjection(cols: 8, rows: 2)
        projection.feed(Data("one\ntwo\nthree\nfour".utf8))

        XCTAssertEqual(projection.snapshot.lines.map(\.text), ["one", "two", "three", "four"])
        XCTAssertEqual(projection.snapshot.viewportLines.map(\.text), ["three", "four"])
    }

    func testViewportLineCountRemainsBoundedAcrossRepeatedResizes() {
        var projection = TerminalTextProjection(cols: 8, rows: 4)
        projection.feed(Data("one\ntwo\nthree\nfour".utf8))

        for _ in 0 ..< 20 {
            projection.resize(cols: 8, rows: 2)
            XCTAssertLessThanOrEqual(projection.snapshot.viewportLines.count, 2)
            projection.resize(cols: 8, rows: 7)
            XCTAssertLessThanOrEqual(projection.snapshot.viewportLines.count, 7)
        }
    }

    func testAlternateScreenFlagTracksDECMode() {
        var projection = TerminalTextProjection(cols: 80, rows: 24)
        projection.feed(Data("\u{1B}[?1049hvim".utf8))
        XCTAssertTrue(projection.snapshot.alternateScreen)

        projection.feed(Data("\u{1B}[?1049l".utf8))
        XCTAssertFalse(projection.snapshot.alternateScreen)
    }

    func testMouseTrackingModesAreParsed() {
        var projection = TerminalTextProjection(cols: 80, rows: 24)
        projection.feed(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        XCTAssertTrue(projection.snapshot.mouseTracking)
        XCTAssertTrue(projection.snapshot.sgrMouseEncoding)

        projection.feed(Data("\u{1B}[?1000l\u{1B}[?1006l".utf8))
        XCTAssertFalse(projection.snapshot.mouseTracking)
        XCTAssertFalse(projection.snapshot.sgrMouseEncoding)
    }

    func testScrollbackIsBoundedAndLineIDsRemainStable() {
        var projection = TerminalTextProjection(cols: 80, rows: 2, maximumLineCount: 3)
        projection.feed(Data("one\ntwo\nthree".utf8))
        let ids = projection.snapshot.lines.map(\.id)

        projection.feed(Data("\nfour".utf8))

        XCTAssertEqual(projection.snapshot.lines.map(\.text), ["two", "three", "four"])
        XCTAssertEqual(Array(projection.snapshot.lines.prefix(2).map(\.id)), Array(ids.suffix(2)))
    }

    func testResetDropsOldContentAndAllocatesFreshLineID() {
        var projection = TerminalTextProjection(cols: 80, rows: 24)
        projection.feed(Data("old".utf8))
        let oldID = projection.snapshot.lines[0].id

        projection.reset()
        projection.feed(Data("new".utf8))

        XCTAssertEqual(projection.snapshot.text, "new")
        XCTAssertNotEqual(projection.snapshot.lines[0].id, oldID)
    }
}
