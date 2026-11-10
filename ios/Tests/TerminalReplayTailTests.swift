@testable import TTYBuild
import XCTest

final class TerminalReplayTailTests: XCTestCase {
    func testSnapshotEndingInTextHasNoPendingRun() {
        let data = Data("Welcome\r\nprompt> ".utf8)
        XCTAssertEqual(TerminalReplayTail.pendingStart(in: data), data.count)
    }

    func testTrailingControlsAfterTextArePending() {
        let (history, pending) = TerminalReplayTail.split(
            Data("CapLockDelayOverride:0\r\n\u{1b}[?u\u{1b}[0c".utf8)
        )
        XCTAssertEqual(history, Data("CapLockDelayOverride:0".utf8))
        XCTAssertEqual(pending, Data("\r\n\u{1b}[?u\u{1b}[0c".utf8))
    }

    func testQueryFollowedByTextIsHistory() {
        let data = Data("\u{1b}[0cWelcome".utf8)
        XCTAssertEqual(TerminalReplayTail.pendingStart(in: data), data.count)
    }

    func testSequencePayloadsAreNotVisible() {
        let tail = "\u{1b}]11;?\u{1b}\\\u{1b}P+q696e646e\u{1b}\\"
            + "\u{1b}]0;title\u{07}\u{1b}(B\u{1b}[?1049l\u{1b}[0c"
        let (history, pending) = TerminalReplayTail.split(Data("$ \(tail)".utf8))
        XCTAssertEqual(history, Data("$ ".utf8))
        XCTAssertEqual(pending, Data(tail.utf8))
    }

    func testControlOnlySnapshotIsEntirelyPending() {
        let data = Data("\u{1b}[?u\u{1b}[>0q\u{1b}[0c".utf8)
        XCTAssertEqual(TerminalReplayTail.pendingStart(in: data), 0)
    }

    func testUnterminatedSequenceAtEndIsPending() {
        let (history, pending) = TerminalReplayTail.split(Data("ok\u{1b}]11;?".utf8))
        XCTAssertEqual(history, Data("ok".utf8))
        XCTAssertEqual(pending, Data("\u{1b}]11;?".utf8))
    }

    func testMultibyteTextIsVisible() {
        let data = Data("你好\u{1b}[0c".utf8)
        XCTAssertEqual(TerminalReplayTail.pendingStart(in: data), data.count - 4)
    }

    func testSplitHonorsSliceIndices() {
        let data = Data("xxab\u{1b}[0c".utf8).dropFirst(2)
        let (history, pending) = TerminalReplayTail.split(data)
        XCTAssertEqual(Data(history), Data("ab".utf8))
        XCTAssertEqual(Data(pending), Data("\u{1b}[0c".utf8))
    }
}
