import Foundation
import XCTest

@testable import TTYBuildHookKit

/// Stop-time transcript tail scan: last message extraction and the
/// api-error / recovery ordering rule.
final class TranscriptTailTests: XCTestCase {
    private var fixtureURL: URL!

    override func setUpWithError() throws {
        fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttybuild-transcript-\(UUID().uuidString).jsonl")
    }

    override func tearDownWithError() throws {
        if let fixtureURL { try? FileManager.default.removeItem(at: fixtureURL) }
    }

    private func write(lines: [[String: Any]]) throws {
        var data = Data()
        for line in lines {
            data.append(try JSONSerialization.data(withJSONObject: line))
            data.append(0x0A)
        }
        try data.write(to: fixtureURL)
    }

    private func assistant(_ text: String, session: String = "s-1") -> [String: Any] {
        [
            "type": "assistant", "sessionId": session,
            "message": ["role": "assistant", "content": [["type": "text", "text": text]]],
        ]
    }

    private func user(_ text: String, session: String = "s-1") -> [String: Any] {
        [
            "type": "user", "sessionId": session,
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ]
    }

    private func apiError(session: String = "s-1") -> [String: Any] {
        var line = assistant("API Error: 500", session: session)
        line["isApiErrorMessage"] = true
        return line
    }

    func testNormalCompletion() throws {
        try write(lines: [user("do it"), assistant("first"), assistant("All done.")])
        let summary = TranscriptTail.scan(path: fixtureURL.path, sessionId: "s-1")
        XCTAssertEqual(summary.lastMessage, "All done.")
        XCTAssertFalse(summary.isError)
        XCTAssertNil(summary.sessionTitle)
    }

    func testSessionTitleFromAiTitleLine() throws {
        try write(lines: [
            ["type": "ai-title", "aiTitle": "Old title", "sessionId": "s-1"],
            assistant("working"),
            ["type": "ai-title", "aiTitle": "Investigate push status", "sessionId": "s-1"],
        ])
        let summary = TranscriptTail.scan(path: fixtureURL.path, sessionId: "s-1")
        XCTAssertEqual(summary.sessionTitle, "Investigate push status")
    }

    func testCustomTitleOutranksNewerAiTitle() throws {
        try write(lines: [
            ["type": "custom-title", "customTitle": "My release plan"],
            ["type": "ai-title", "aiTitle": "Ship the release"],
        ])
        let summary = TranscriptTail.scan(path: fixtureURL.path, sessionId: "s-1")
        XCTAssertEqual(summary.sessionTitle, "My release plan")
    }

    func testEmptyOrMalformedTitleLinesIgnored() throws {
        try write(lines: [
            ["type": "ai-title", "aiTitle": "   "],
            ["type": "custom-title", "aiTitle": "wrong key"],
            ["type": "ai-title", "aiTitle": 7],
        ])
        let summary = TranscriptTail.scan(path: fixtureURL.path, sessionId: "s-1")
        XCTAssertNil(summary.sessionTitle)
    }

    func testConcatenatesTextParts() throws {
        try write(lines: [[
            "type": "assistant", "sessionId": "s-1",
            "message": ["content": [
                ["type": "text", "text": "part one"],
                ["type": "tool_use", "name": "Bash"],
                ["type": "text", "text": "part two"],
            ]],
        ]])
        let summary = TranscriptTail.scan(path: fixtureURL.path, sessionId: "s-1")
        XCTAssertEqual(summary.lastMessage, "part one part two")
    }

    func testApiErrorLastTurnSetsError() throws {
        try write(lines: [user("do it"), assistant("working"), apiError()])
        let summary = TranscriptTail.scan(path: fixtureURL.path, sessionId: "s-1")
        XCTAssertTrue(summary.isError)
        XCTAssertEqual(summary.lastMessage, "API Error: 500")
    }

    func testApiErrorFollowedByLaterUserLineIsNotError() throws {
        try write(lines: [apiError(), user("try again"), assistant("recovered")])
        let summary = TranscriptTail.scan(path: fixtureURL.path, sessionId: "s-1")
        XCTAssertFalse(summary.isError)
        XCTAssertEqual(summary.lastMessage, "recovered")
    }

    func testApiErrorForOtherSessionIgnored() throws {
        try write(lines: [assistant("mine"), apiError(session: "other")])
        let summary = TranscriptTail.scan(path: fixtureURL.path, sessionId: "s-1")
        XCTAssertFalse(summary.isError)
    }

    func testMessageCappedAndStripped() throws {
        try write(lines: [assistant("a\u{07}b" + String(repeating: "x", count: 600))])
        let summary = TranscriptTail.scan(path: fixtureURL.path, sessionId: "s-1")
        let message = try XCTUnwrap(summary.lastMessage)
        XCTAssertEqual(message.count, 300)
        XCTAssertFalse(message.unicodeScalars.contains { $0.value < 0x20 })
    }

    func testHugeFileOnlyTailRead() throws {
        // Early lines (beyond the 256 KiB tail) carry a decoy message; the
        // tail carries the real one. Padding lines are valid JSON so a parser
        // reading more than the tail would pick up the decoy.
        var lines: [[String: Any]] = [assistant("DECOY — must not be seen")]
        let filler = String(repeating: "f", count: 1024)
        for _ in 0..<400 { lines.append(["type": "padding", "data": filler]) }
        lines.append(assistant("real tail message"))
        try write(lines: lines)
        let size = try FileManager.default
            .attributesOfItem(atPath: fixtureURL.path)[.size] as! Int
        XCTAssertGreaterThan(size, TranscriptTail.tailLimit)

        let summary = TranscriptTail.scan(path: fixtureURL.path, sessionId: "s-1")
        XCTAssertEqual(summary.lastMessage, "real tail message")
        XCTAssertFalse(summary.isError)
    }

    func testMissingFileAndGarbageDegradeSilently() throws {
        var summary = TranscriptTail.scan(path: "/nonexistent/never.jsonl", sessionId: "s-1")
        XCTAssertNil(summary.lastMessage)
        XCTAssertFalse(summary.isError)

        try Data("not json at all\n{broken\n".utf8).write(to: fixtureURL)
        summary = TranscriptTail.scan(path: fixtureURL.path, sessionId: "s-1")
        XCTAssertNil(summary.lastMessage)
        XCTAssertFalse(summary.isError)
    }
}
