import Foundation
import TTYBuildKit
import XCTest

@testable import TTYBuildDaemonCore

/// Full daemon against its unix control socket (PROTOCOL.md §5): ls / new /
/// kill / pair / status. The service points at a closed port; the relay
/// client just keeps retrying, which the control plane must not depend on.
final class DaemonControlTests: XCTestCase {
    private var home: TTYBuildHome!
    private var daemon: Daemon!
    private var factory: IdentityFactory!

    override func setUpWithError() throws {
        // sockaddr_un.sun_path caps unix socket paths at 104 bytes, so the
        // test home must live somewhere short — not NSTemporaryDirectory().
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "ttybuild-t-\(UUID().uuidString.prefix(8))", isDirectory: true
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

    private func send(_ request: [String: Any]) throws -> [String: Any] {
        try ControlClient.roundTrip(socketPath: home.socketPath, request: request)
    }

    func testLsNewKillRoundTrip() throws {
        var reply = try send(["cmd": "ls"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual((reply["sessions"] as? [Any])?.count, 0)
        XCTAssertEqual(reply["client"] as? String, "none")
        XCTAssertEqual(reply["service"] as? String, "https://127.0.0.1:1")

        reply = try send(["cmd": "new"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let id = try XCTUnwrap(reply["id"] as? Int)

        reply = try send(["cmd": "ls"])
        let sessions = try XCTUnwrap(reply["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0]["id"] as? Int, id)
        XCTAssertEqual(sessions[0]["alive"] as? Bool, true)
        XCTAssertEqual(sessions[0]["cols"] as? Int, 120)
        XCTAssertEqual(sessions[0]["rows"] as? Int, 40)

        reply = try send(["cmd": "kill", "id": id])
        XCTAssertEqual(reply["ok"] as? Bool, true)

        reply = try send(["cmd": "ls"])
        XCTAssertEqual((reply["sessions"] as? [Any])?.count, 0)

        reply = try send(["cmd": "kill", "id": id])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertNotNil(reply["err"])
    }

    func testInProcessServiceAPI() throws {
        var snapshot = daemon.snapshot()
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertFalse(snapshot.clientConnected)

        let id = try daemon.createSession()
        snapshot = daemon.snapshot()
        XCTAssertEqual(snapshot.sessions.map(\.id), [id])

        XCTAssertTrue(daemon.closeSession(id: id))
        XCTAssertFalse(daemon.closeSession(id: id))
        XCTAssertTrue(daemon.snapshot().sessions.isEmpty)

        let invitation = try daemon.createPairingInvitation()
        XCTAssertEqual(invitation.code.digits.count, PairingCode.digitCount)
        XCTAssertGreaterThan(invitation.expiresAt, Date())
        daemon.cancelPairingInvitation()
    }

    func testClaimReversePairingSubmitsCodeAndComputerNameAgainstCurrentIdentity() throws {
        let identity = try XCTUnwrap(home.loadIdentity())
        factory.clearEvents()
        try daemon.claimReversePairing(
            code: PairingCode("01234567"),
            computerName: "Studio Mac"
        )
        XCTAssertEqual(
            factory.events,
            ["claim:01234567:Studio Mac:\(identity.computer.computerID)"]
        )
    }

    func testPairReturnsSingleUseCodesAndResetRotatesComputer() throws {
        let originalIdentity = try XCTUnwrap(home.loadIdentity())
        let first = try send(["cmd": "pair"])
        XCTAssertEqual(first["ok"] as? Bool, true)
        let firstCode = try PairingCode(try XCTUnwrap(first["code"] as? String))
        XCTAssertNotNil(first["expiresAt"] as? Int64)

        let next = try send(["cmd": "pair"])
        let nextCode = try PairingCode(try XCTUnwrap(next["code"] as? String))
        XCTAssertNotEqual(nextCode, firstCode)

        factory.clearEvents()
        let reset = try send(["cmd": "pair", "reset": true])
        _ = try PairingCode(try XCTUnwrap(reset["code"] as? String))
        let resetIdentity = try XCTUnwrap(home.loadIdentity())
        XCTAssertNotEqual(resetIdentity.computer.computerID, originalIdentity.computer.computerID)
        XCTAssertNotEqual(resetIdentity.computer.secret, originalIdentity.computer.secret)

        let resetEvents = factory.events
        XCTAssertEqual(resetEvents.count, 3)
        XCTAssertTrue(resetEvents[0].hasPrefix("delete:"))
        XCTAssertEqual(resetEvents[1], "create")
        XCTAssertTrue(resetEvents[2].hasPrefix("pairing:"))
    }

    func testResetRevocationFailurePreservesOldIdentityWithoutFallbackRegistration() throws {
        let previous = try XCTUnwrap(home.loadIdentity())
        factory.clearEvents()
        factory.failDelete = true

        let reset = try send(["cmd": "pair", "reset": true])

        XCTAssertEqual(reset["ok"] as? Bool, false)
        XCTAssertTrue((reset["err"] as? String)?.contains("revocation failed") == true)
        XCTAssertEqual(try home.loadIdentity(), previous)
        XCTAssertNil(try home.loadIdentityResetState())
        XCTAssertEqual(factory.events, ["delete:\(previous.computer.computerID)"])

        factory.failDelete = false
        let ordinaryPair = try send(["cmd": "pair"])
        XCTAssertEqual(ordinaryPair["ok"] as? Bool, true)
        XCTAssertEqual(try home.loadIdentity(), previous)
    }

    func testResetCreateFailureLeavesFailClosedJournalAndResumesWithoutRedeleting() throws {
        let previous = try XCTUnwrap(home.loadIdentity())
        factory.clearEvents()
        factory.failNextCreate = true

        let failed = try send(["cmd": "pair", "reset": true])

        XCTAssertEqual(failed["ok"] as? Bool, false)
        XCTAssertTrue((failed["err"] as? String)?.contains("replacement registration failed") == true)
        XCTAssertEqual(try home.loadIdentity(), previous)
        XCTAssertEqual(try home.loadIdentityResetState()?.phase, .revoked)
        XCTAssertEqual(
            factory.events,
            ["delete:\(previous.computer.computerID)", "create"]
        )

        let unsafePair = try send(["cmd": "pair"])
        XCTAssertEqual(unsafePair["ok"] as? Bool, false)
        XCTAssertTrue((unsafePair["err"] as? String)?.contains("reset is incomplete") == true)
        XCTAssertThrowsError(
            try Daemon(
                home: home,
                sessionOptions: SessionManager.Options(shell: "/bin/sh", shellArguments: []),
                serviceActions: factory.actions
            )
        ) { error in
            guard case Daemon.DaemonError.identityResetPending(.revoked) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        factory.clearEvents()
        let resumed = try send(["cmd": "pair", "reset": true])
        XCTAssertEqual(resumed["ok"] as? Bool, true)
        XCTAssertEqual(factory.events.first, "create")
        XCTAssertFalse(factory.events.contains { $0.hasPrefix("delete:") })
        XCTAssertNil(try home.loadIdentityResetState())
        XCTAssertNotEqual(try home.loadIdentity(), previous)
    }

    func testStatusShape() throws {
        let reply = try send(["cmd": "status"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["service"] as? String, "https://127.0.0.1:1")
        XCTAssertEqual(reply["client"] as? String, "none")
        XCTAssertEqual((reply["computer"] as? String)?.count, 32)
        XCTAssertNotNil(reply["uptime"])
        XCTAssertTrue(["connected", "connecting"].contains(reply["state"] as? String ?? ""))
    }

    func testUnknownAndMalformedCommands() throws {
        let unknown = try send(["cmd": "frobnicate"])
        XCTAssertEqual(unknown["ok"] as? Bool, false)

        let missingId = try send(["cmd": "kill"])
        XCTAssertEqual(missingId["ok"] as? Bool, false)
    }
}
