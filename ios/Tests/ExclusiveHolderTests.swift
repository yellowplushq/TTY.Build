@testable import TTYBuild
import TTYBuildKit
import XCTest

/// Exclusive-holder handling on the iOS side
/// (docs/EXCLUSIVE_ATTACH_DESIGN.md §5): `takeover` frames maintain the
/// holder map, and holder state resolves to interactive / unheld / taken
/// over with the legacy-daemon default (no entry → interactive).
@MainActor
final class ExclusiveHolderTests: XCTestCase {
    private let myPrincipal = "fedcba9876543210fedcba9876543210"

    private func makeConnection() throws -> ComputerConnection {
        let binding = try ComputerBinding(
            serviceURL: URL(string: "https://example.com")!,
            computerID: "0123456789abcdef0123456789abcdef",
            secret: Data(repeating: 0x42, count: 32)
        )
        return ComputerConnection(
            binding: binding,
            clientID: myPrincipal,
            clientToken: "token"
        )
    }

    private func terminalID(_ sid: Int) -> TerminalID {
        TerminalID(computerID: "0123456789abcdef0123456789abcdef", sid: sid)
    }

    // MARK: - ComputerConnection holder map

    func testTakeoverFramesMaintainHolderMap() throws {
        let connection = try makeConnection()
        XCTAssertTrue(connection.holders.isEmpty)

        connection.handle(frame: try Frame.control(
            .takeover(id: 3, holder: HolderInfo(kind: .attach, name: "iTerm"))
        ))
        XCTAssertEqual(connection.holders[3]?.kind, .attach)
        XCTAssertEqual(connection.holders[3]?.name, "iTerm")

        connection.handle(frame: try Frame.control(
            .takeover(id: 3, holder: HolderInfo(kind: .none))
        ))
        XCTAssertEqual(connection.holders[3]?.kind, HolderInfo.Kind.none)
    }

    func testSessionsListPrunesHoldersOfRemovedSessions() throws {
        let connection = try makeConnection()
        connection.handle(frame: try Frame.control(
            .takeover(id: 1, holder: HolderInfo(kind: .attach))
        ))
        connection.handle(frame: try Frame.control(
            .takeover(id: 2, holder: HolderInfo(kind: .attach))
        ))

        let survivor = SessionInfo(
            id: 2, title: "zsh", cwd: "/", rows: 40, cols: 120,
            createdAt: 0, alive: true
        )
        connection.handle(frame: try Frame.control(.sessions(list: [survivor])))
        XCTAssertNil(connection.holders[1])
        XCTAssertNotNil(connection.holders[2])
    }

    // MARK: - Holder-state resolution

    func testNoEntryMeansLegacyInteractive() {
        XCTAssertEqual(
            TerminalManager.holderState(
                for: terminalID(1), in: [:], clientID: myPrincipal
            ),
            .interactive
        )
    }

    func testOwnClientHoldIsInteractive() {
        let holders = [
            terminalID(1): HolderInfo(kind: .client, principal: myPrincipal)
        ]
        XCTAssertEqual(
            TerminalManager.holderState(
                for: terminalID(1), in: holders, clientID: myPrincipal
            ),
            .interactive
        )
    }

    func testForeignClientHoldIsTakenOver() {
        let holders = [
            terminalID(1): HolderInfo(
                kind: .client,
                principal: "0000000000000000000000000000ffff",
                name: "iPhone"
            )
        ]
        XCTAssertEqual(
            TerminalManager.holderState(
                for: terminalID(1), in: holders, clientID: myPrincipal
            ),
            .takenOver(name: "iPhone")
        )
    }

    func testAttachHoldIsTakenOverWithTerminalFallbackName() {
        let named = [terminalID(1): HolderInfo(kind: .attach, name: "iTerm")]
        XCTAssertEqual(
            TerminalManager.holderState(
                for: terminalID(1), in: named, clientID: myPrincipal
            ),
            .takenOver(name: "iTerm")
        )
        let unnamed = [terminalID(1): HolderInfo(kind: .attach)]
        XCTAssertEqual(
            TerminalManager.holderState(
                for: terminalID(1), in: unnamed, clientID: myPrincipal
            ),
            .takenOver(name: "Terminal")
        )
    }

    func testNoneHolderIsUnheld() {
        let holders = [terminalID(1): HolderInfo(kind: .none)]
        XCTAssertEqual(
            TerminalManager.holderState(
                for: terminalID(1), in: holders, clientID: myPrincipal
            ),
            .unheld
        )
    }
}
