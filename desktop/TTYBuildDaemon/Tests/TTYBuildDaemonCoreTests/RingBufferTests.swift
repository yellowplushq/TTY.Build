import Foundation
import XCTest

@testable import TTYBuildDaemonCore

final class RingBufferTests: XCTestCase {
    func testAppendBelowCapacity() {
        var ring = RingBuffer(capacity: 8)
        ring.append(Data("abc".utf8))
        XCTAssertEqual(ring.snapshot(), Data("abc".utf8))
        ring.append(Data("de".utf8))
        XCTAssertEqual(ring.snapshot(), Data("abcde".utf8))
    }

    func testWrapKeepsMostRecentBytes() {
        var ring = RingBuffer(capacity: 4)
        ring.append(Data("abcdef".utf8))
        XCTAssertEqual(ring.snapshot(), Data("cdef".utf8))
        ring.append(Data("gh".utf8))
        XCTAssertEqual(ring.snapshot(), Data("efgh".utf8))
    }

    func testOversizedAppendKeepsTail() {
        var ring = RingBuffer(capacity: 4)
        ring.append(Data("0123456789".utf8))
        XCTAssertEqual(ring.snapshot(), Data("6789".utf8))
    }

    func testManySmallAppendsAcrossWrapBoundary() {
        var ring = RingBuffer(capacity: 5)
        for byte in "abcdefghijk".utf8 {
            ring.append(Data([byte]))
        }
        XCTAssertEqual(ring.snapshot(), Data("ghijk".utf8))
    }
}

final class OSCTitleParserTests: XCTestCase {
    func testOSC0AndOSC2WithBELAndST() {
        var parser = OSCTitleParser()
        let stream = "x\u{1b}]0;first\u{07}y\u{1b}]2;second\u{1b}\\z"
        XCTAssertEqual(parser.consume(Data(stream.utf8)), ["first", "second"])
    }

    func testTitleSplitAcrossChunks() {
        var parser = OSCTitleParser()
        XCTAssertEqual(parser.consume(Data("\u{1b}]2;he".utf8)), [])
        XCTAssertEqual(parser.consume(Data("llo\u{07}".utf8)), ["hello"])
    }

    func testNonTitleOSCIgnored() {
        var parser = OSCTitleParser()
        let stream = "\u{1b}]7;file:///tmp\u{07}\u{1b}]0;real\u{07}"
        XCTAssertEqual(parser.consume(Data(stream.utf8)), ["real"])
    }
}
