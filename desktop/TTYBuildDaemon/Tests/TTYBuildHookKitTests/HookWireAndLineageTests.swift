import Darwin
import Foundation
import XCTest

@testable import TTYBuildHookKit

final class HookWireAndLineageTests: XCTestCase {
    func testRequestLineShape() throws {
        let report = HookReport(
            event: "tool", agentSessionId: "s-1",
            sessionName: "TTY.Build release", cwd: "/tmp/p",
            action: "Bash: git status",
            transcriptPath: "/Users/test/.claude/projects/s-1.jsonl"
        )
        let lineage = [
            LineageEntry(pid: 10, name: "zsh", tty: "/dev/ttys003"),
            LineageEntry(pid: 9, name: "claude"),
        ]
        let line = try XCTUnwrap(
            HookWire.requestLine(agent: "claude", report: report, lineage: lineage)
        )
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertFalse(line.dropLast().contains(0x0A), "wire form is one line")

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
        XCTAssertEqual(object["cmd"] as? String, "agent-event")
        XCTAssertEqual(object["noReply"] as? Bool, true)
        XCTAssertEqual(object["agent"] as? String, "claude")
        XCTAssertEqual(object["event"] as? String, "tool")
        XCTAssertEqual(object["agentSessionId"] as? String, "s-1")
        XCTAssertEqual(object["sessionName"] as? String, "TTY.Build release")
        XCTAssertEqual(object["cwd"] as? String, "/tmp/p")
        XCTAssertEqual(object["action"] as? String, "Bash: git status")
        XCTAssertEqual(
            object["transcriptPath"] as? String,
            "/Users/test/.claude/projects/s-1.jsonl"
        )
        XCTAssertNil(object["prompt"])
        XCTAssertNil(object["agentError"])
        let wireLineage = try XCTUnwrap(object["lineage"] as? [[String: Any]])
        XCTAssertEqual(wireLineage.count, 2)
        XCTAssertEqual(wireLineage[0]["pid"] as? Int, 10)
        XCTAssertEqual(wireLineage[0]["tty"] as? String, "/dev/ttys003")
        XCTAssertEqual(wireLineage[1]["name"] as? String, "claude")
        XCTAssertNil(wireLineage[1]["tty"])
    }

    func testRequestLineCarriesSeqAgentPidAndNotifyKind() throws {
        let report = HookReport(
            event: "notify", agentSessionId: "s-1", message: "Permission needed",
            notifyKind: "permission"
        )
        let line = try XCTUnwrap(HookWire.requestLine(
            agent: "claude", report: report, lineage: [],
            seq: 123_456_789, agentPid: 4242
        ))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
        XCTAssertEqual((object["seq"] as? NSNumber)?.uint64Value, 123_456_789)
        XCTAssertEqual(object["agentPid"] as? Int, 4242)
        XCTAssertEqual(object["notifyKind"] as? String, "permission")

        // Old-style calls carry none of the new fields.
        let bare = try XCTUnwrap(HookWire.requestLine(
            agent: "claude",
            report: HookReport(event: "busy", agentSessionId: "s-1"),
            lineage: []
        ))
        let bareObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bare) as? [String: Any]
        )
        XCTAssertNil(bareObject["seq"])
        XCTAssertNil(bareObject["agentPid"])
        XCTAssertNil(bareObject["notifyKind"])
    }

    func testRequestLineCarriesAgentError() throws {
        let report = HookReport(
            event: "stop", agentSessionId: "s-1", message: "API Error", agentError: true
        )
        let line = try XCTUnwrap(
            HookWire.requestLine(agent: "claude", report: report, lineage: [])
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
        XCTAssertEqual(object["agentError"] as? Bool, true)
        XCTAssertEqual(object["message"] as? String, "API Error")
    }

    func testLineageWalkFindsSelfAncestry() {
        let entries = ProcessLineage.walk(from: getpid())
        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(entries.first?.pid, getpid())
        XCTAssertFalse(entries.first?.name.isEmpty ?? true)
        XCTAssertLessThanOrEqual(entries.count, 15)
        // Pids strictly walk upward without cycles.
        XCTAssertEqual(Set(entries.map(\.pid)).count, entries.count)
    }

    func testLineageRejectsNonPositivePids() {
        XCTAssertTrue(ProcessLineage.walk(from: 0).isEmpty)
        XCTAssertTrue(ProcessLineage.walk(from: -5).isEmpty)
    }

    func testHookInputDoesNotWaitForAnInheritedOpenWriter() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let payload = Data(#"{"session_id":"bounded"}"#.utf8)
        XCTAssertEqual(
            payload.withUnsafeBytes {
                Darwin.write(descriptors[1], $0.baseAddress, $0.count)
            },
            payload.count
        )

        let started = Date()
        let received = HookInput.read(
            fd: descriptors[0],
            cap: 1024,
            budgetMilliseconds: 30
        )

        XCTAssertEqual(received, payload)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
    }
}
