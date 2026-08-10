import Foundation
import TTYBuildKit
import XCTest

@testable import TTYBuildDaemonCore

/// Full daemon against the upgraded `attach` stream on the unix control
/// socket (docs/EXCLUSIVE_ATTACH_DESIGN.md §4): handshake, claim/takeover,
/// resize-before-replay, exclusive stdin, disconnect release, close teardown.
final class DaemonAttachTests: XCTestCase {
    private var home: TTYBuildHome!
    private var daemon: Daemon!
    private var factory: IdentityFactory!

    override func setUpWithError() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "ttybuild-a-\(UUID().uuidString.prefix(8))", isDirectory: true
            )
        home = TTYBuildHome(directory: directory)
        try home.save(config: .init(service: "https://127.0.0.1:1"))
        factory = IdentityFactory()
        daemon = try Daemon(
            home: home,
            sessionOptions: SessionManager.Options(shell: "/bin/sh", shellArguments: []),
            serviceActions: factory.actions
        )
        try daemon.start()
    }

    override func tearDownWithError() throws {
        daemon?.shutdown()
        if let home { try? FileManager.default.removeItem(at: home.directory) }
    }

    private func attach(_ request: [String: Any]) throws
        -> (AttachStream, AttachStream.Handshake)
    {
        try AttachStream.connect(
            socketPath: home.socketPath, request: request, readTimeout: 5
        )
    }

    /// Reads frames until `predicate` accepts one; fails the test after
    /// `limit` frames to bound a runaway stream.
    private func readUntil(
        _ stream: AttachStream, limit: Int = 200,
        _ predicate: (Frame) -> Bool
    ) throws -> Frame {
        for _ in 0..<limit {
            guard let frame = try stream.readFrame() else { break }
            if predicate(frame) { return frame }
        }
        throw AttachStream.StreamError.rejected("expected frame never arrived")
    }

    func testAttachRejectsUnknownSessionAndMissingId() throws {
        XCTAssertThrowsError(try attach(["cmd": "attach", "id": 99]))
        XCTAssertThrowsError(try attach(["cmd": "attach"]))
    }

    func testCreateAndAttachReplaysAfterTakeoverAndResize() throws {
        let (stream, handshake) = try attach(
            ["cmd": "attach", "new": true, "cols": 80, "rows": 24]
        )
        defer { stream.close() }
        XCTAssertTrue(handshake.alive)
        XCTAssertFalse(handshake.title.isEmpty)

        var sawTakeover = false
        var sawResize = false
        let replay = try readUntil(stream) { frame in
            if frame.type == .ctl,
               let message = try? frame.controlMessage(),
               case let .takeover(id, holder) = message
            {
                XCTAssertEqual(id, handshake.sessionId)
                XCTAssertEqual(holder.kind, .attach)
                sawTakeover = true
            }
            if frame.type == .resize {
                XCTAssertTrue(sawTakeover, "takeover must precede replay resize")
                let size = try? frame.resizeSize()
                XCTAssertEqual(size?.cols, 80)
                XCTAssertEqual(size?.rows, 24)
                sawResize = true
            }
            return frame.type == .replay
        }
        XCTAssertTrue(sawResize, "resize must precede replay")
        XCTAssertEqual(replay.sessionId, UInt32(handshake.sessionId))
    }

    func testHolderStdinEchoesWhileNonHolderStdinIsDropped() throws {
        let (first, handshake) = try attach(["cmd": "attach", "new": true])
        defer { first.close() }
        _ = try readUntil(first) { $0.type == .replay }

        // Second attach steals the hold; the first connection observes it.
        let (second, _) = try attach(["cmd": "attach", "id": handshake.sessionId])
        defer { second.close() }
        _ = try readUntil(second) { $0.type == .replay }
        _ = try readUntil(first) { frame in
            guard frame.type == .ctl,
                  let message = try? frame.controlMessage(),
                  case let .takeover(_, holder) = message
            else { return false }
            return holder.kind == .attach
        }

        // The PTY serializes echo: if the non-holder's line were applied it
        // would appear before the holder's. Its absence is deterministic.
        let sid = UInt32(handshake.sessionId)
        try first.send(Frame.stdin(sessionId: sid, data: Data("echo STOLEN\n".utf8)))
        try second.send(Frame.stdin(sessionId: sid, data: Data("echo WINNER\n".utf8)))

        var transcript = Data()
        _ = try readUntil(second) { frame in
            guard frame.type == .stdout else { return false }
            transcript.append(frame.payload)
            return String(decoding: transcript, as: UTF8.self).contains("WINNER")
        }
        XCTAssertFalse(
            String(decoding: transcript, as: UTF8.self).contains("STOLEN"),
            "a non-holder's stdin must be dropped"
        )
    }

    func testReclaimRestoresInteractivityAndReplays() throws {
        let (first, handshake) = try attach(["cmd": "attach", "new": true])
        defer { first.close() }
        _ = try readUntil(first) { $0.type == .replay }

        let (second, _) = try attach(["cmd": "attach", "id": handshake.sessionId])
        defer { second.close() }
        _ = try readUntil(second) { $0.type == .replay }

        // First reclaims: expect a takeover answer and a fresh replay.
        let sid = UInt32(handshake.sessionId)
        try first.send(try Frame.control(.claim(id: handshake.sessionId, req: nil)))
        _ = try readUntil(first) { $0.type == .replay }

        try first.send(Frame.stdin(sessionId: sid, data: Data("echo BACK\n".utf8)))
        var transcript = Data()
        _ = try readUntil(first) { frame in
            guard frame.type == .stdout else { return false }
            transcript.append(frame.payload)
            return String(decoding: transcript, as: UTF8.self).contains("BACK")
        }
    }

    func testHolderDisconnectBroadcastsReleaseToViewers() throws {
        let (viewer, handshake) = try attach(["cmd": "attach", "new": true])
        defer { viewer.close() }
        _ = try readUntil(viewer) { $0.type == .replay }

        let (holder, _) = try attach(["cmd": "attach", "id": handshake.sessionId])
        _ = try readUntil(holder) { $0.type == .replay }
        _ = try readUntil(viewer) { frame in
            guard frame.type == .ctl,
                  let message = try? frame.controlMessage(),
                  case let .takeover(_, info) = message
            else { return false }
            return info.kind == .attach
        }

        holder.close()
        _ = try readUntil(viewer) { frame in
            guard frame.type == .ctl,
                  let message = try? frame.controlMessage(),
                  case let .takeover(id, info) = message
            else { return false }
            XCTAssertEqual(id, handshake.sessionId)
            return info.kind == HolderInfo.Kind.none
        }
    }

    func testKillWhileAttachedReportsClosureAndEndsStream() throws {
        let (stream, handshake) = try attach(["cmd": "attach", "new": true])
        defer { stream.close() }
        _ = try readUntil(stream) { $0.type == .replay }

        let reply = try ControlClient.roundTrip(
            socketPath: home.socketPath,
            request: ["cmd": "kill", "id": handshake.sessionId]
        )
        XCTAssertEqual(reply["ok"] as? Bool, true)

        var sawClosure = false
        while let frame = (try? stream.readFrame()).flatMap({ $0 }) {
            if frame.type == .ctl,
               let message = try? frame.controlMessage(),
               case .err = message
            {
                sawClosure = true
            }
        }
        XCTAssertTrue(sawClosure, "a killed session must report closure before EOF")
    }

    func testAttachToExitedSessionStillReplays() throws {
        let (first, handshake) = try attach(["cmd": "attach", "new": true])
        let sid = UInt32(handshake.sessionId)
        _ = try readUntil(first) { $0.type == .replay }
        try first.send(Frame.stdin(sessionId: sid, data: Data("echo LAST; exit\n".utf8)))
        _ = try readUntil(first) { frame in
            guard frame.type == .ctl,
                  let message = try? frame.controlMessage(),
                  case .exit = message
            else { return false }
            return true
        }
        first.close()

        let (second, handshake2) = try attach(
            ["cmd": "attach", "id": handshake.sessionId]
        )
        defer { second.close() }
        XCTAssertFalse(handshake2.alive)
        var transcript = Data()
        _ = try readUntil(second) { frame in
            guard frame.type == .replay else { return false }
            transcript.append(frame.payload)
            return String(decoding: transcript, as: UTF8.self).contains("LAST")
        }
    }
}
