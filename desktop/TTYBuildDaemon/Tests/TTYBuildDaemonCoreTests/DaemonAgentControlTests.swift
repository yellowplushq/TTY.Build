import Darwin
import Foundation
import TTYBuildHookKit
import TTYBuildKit
import XCTest

@testable import TTYBuildDaemonCore

/// Full daemon against its unix control socket: `agent-event` ingest and the
/// `agents` snapshot command (PROTOCOL.md §7), including the reporter's own
/// wire encoding and socket client end to end.
final class DaemonAgentControlTests: XCTestCase {
    private var home: TTYBuildHome!
    private var daemon: Daemon!

    override func setUpWithError() throws {
        // sockaddr_un.sun_path caps unix socket paths at 104 bytes, so the
        // test home must live somewhere short — not NSTemporaryDirectory().
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "ttybuild-a-\(UUID().uuidString.prefix(8))", isDirectory: true
            )
        home = TTYBuildHome(directory: directory)
        try home.save(config: .init(service: "https://127.0.0.1:1"))
        try home.save(identity: HostIdentity(
            computer: try ComputerBinding(
                serviceURL: URL(string: "https://127.0.0.1:1")!,
                computerID: String(repeating: "a", count: 32),
                secret: Data(repeating: 1, count: 32)
            ),
            hostToken: "host-token"
        ))
        daemon = try Daemon(
            home: home,
            sessionOptions: SessionManager.Options(shell: "/bin/sh", shellArguments: [])
        )
        try daemon.start()
    }

    override func tearDownWithError() throws {
        daemon?.shutdown()
        if let home { try? FileManager.default.removeItem(at: home.directory) }
    }

    private func send(_ request: [String: Any]) throws -> [String: Any] {
        try ControlClient.roundTrip(socketPath: home.socketPath, request: request)
    }

    func testAgentEventThenAgentsSnapshot() throws {
        var reply = try send(["cmd": "agents"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual((reply["agents"] as? [Any])?.count, 0)

        reply = try send([
            "cmd": "agent-event",
            "agent": "claude",
            "event": "prompt",
            "agentSessionId": "abc-123",
            "sessionName": "Fix test suite",
            "cwd": "/tmp/project",
            "prompt": "fix the tests",
            "lineage": [
                ["pid": Int(getpid()), "name": "claude", "tty": "/dev/ttys042"],
                ["pid": 1, "name": "launchd"],
            ],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true)

        reply = try send(["cmd": "agents"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let list = try XCTUnwrap(reply["agents"] as? [[String: Any]])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["id"] as? String, "abc-123")
        XCTAssertEqual(list[0]["agent"] as? String, "claude")
        XCTAssertEqual(list[0]["state"] as? String, "running")
        XCTAssertEqual(list[0]["sessionName"] as? String, "Fix test suite")
        XCTAssertEqual(list[0]["cwd"] as? String, "/tmp/project")
        XCTAssertEqual(list[0]["prompt"] as? String, "fix the tests")
        XCTAssertNil(list[0]["sessionId"], "no daemon session owns this tty")
        XCTAssertNotNil(list[0]["updatedAt"])
    }

    func testHookKitWireLineRoundTrip() throws {
        // The reporter's own encoding and socket client, end to end.
        let report = HookReport(
            event: "notify", agentSessionId: "wire-1", cwd: "/tmp/w",
            message: "Permission needed"
        )
        let lineage = [LineageEntry(pid: getpid(), name: "claude")]
        let line = try XCTUnwrap(
            HookWire.requestLine(agent: "claude", report: report, lineage: lineage)
        )
        XCTAssertTrue(HookSocket.send(line, socketPath: home.socketPath))

        var list: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(1)
        repeat {
            let reply = try send(["cmd": "agents"])
            list = reply["agents"] as? [[String: Any]] ?? []
            if !list.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["id"] as? String, "wire-1")
        XCTAssertEqual(list[0]["state"] as? String, "waiting")
        XCTAssertEqual(list[0]["message"] as? String, "Permission needed")
    }

    func testSessionEndRemovesRecord() throws {
        _ = try send([
            "cmd": "agent-event", "agent": "claude", "event": "prompt",
            "agentSessionId": "gone-1",
            "lineage": [["pid": Int(getpid()), "name": "claude"]],
        ])
        _ = try send([
            "cmd": "agent-event", "agent": "claude", "event": "session-end",
            "agentSessionId": "gone-1",
        ])
        let reply = try send(["cmd": "agents"])
        XCTAssertEqual((reply["agents"] as? [Any])?.count, 0)
    }

    func testAgentEventValidation() throws {
        let reply = try send(["cmd": "agent-event", "agent": "claude"])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertNotNil(reply["err"])
    }
}
