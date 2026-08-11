import Combine
@testable import TTYBuild
import TTYBuildKit
import XCTest

/// Optimistic create/close on the tab list: a create shows a placeholder tab
/// immediately (rekeyed in place by the daemon's `created` echo), and a close
/// removes the tab immediately (confirmed against subsequent session lists,
/// which suppress and re-close a still-listed terminal).
@MainActor
final class TerminalOptimisticUpdateTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    private let computerID = "0123456789abcdef0123456789abcdef"

    private func makeManager() -> TerminalManager {
        TerminalManager(pairingStore: PairingStore(
            apiFactory: { TTYBuildServiceAPI(serviceURL: $0) },
            stateReader: { nil },
            stateWriter: { _ in }
        ))
    }

    private func makeConnection() throws -> ComputerConnection {
        let binding = try ComputerBinding(
            serviceURL: URL(string: "https://example.com")!,
            computerID: computerID,
            secret: Data(repeating: 0x42, count: 32)
        )
        return ComputerConnection(
            binding: binding,
            clientID: "fedcba9876543210fedcba9876543210",
            clientToken: "token"
        )
    }

    /// Publishes a fresh directory + session list, as the relay/daemon would.
    private func publish(
        _ connection: ComputerConnection,
        revision: UInt64,
        sessions: [SessionInfo]
    ) throws {
        connection.handle(metadata: .terminalDirectory(.init(
            revision: revision,
            online: true,
            hostName: "Mac",
            sessions: sessions.map { .init(id: $0.id, alive: $0.alive) },
            updatedAt: 0
        )))
        connection.handle(frame: try Frame.control(.sessions(list: sessions)))
    }

    private func session(id: Int, title: String = "zsh") -> SessionInfo {
        SessionInfo(
            id: id, title: title, cwd: "/tmp", rows: 40, cols: 120,
            createdAt: 1, alive: true
        )
    }

    func testCreateShowsPlaceholderTabImmediately() throws {
        let manager = makeManager()
        let connection = try makeConnection()
        manager.attach(connection)
        try publish(connection, revision: 1, sessions: [])

        var creations: [TerminalID] = []
        manager.ownCreations.sink { creations.append($0) }.store(in: &cancellables)

        manager.createTerminal(on: computerID, cols: 120, rows: 40)

        XCTAssertEqual(manager.terminals.count, 1)
        let placeholder = try XCTUnwrap(manager.terminals.first)
        XCTAssertTrue(placeholder.isPlaceholder)
        XCTAssertTrue(placeholder.info.alive)
        XCTAssertEqual(manager.activeID, placeholder.id)
        XCTAssertEqual(creations, [placeholder.id])
    }

    func testCreatedEchoRekeysPlaceholderInPlace() throws {
        let manager = makeManager()
        let connection = try makeConnection()
        manager.attach(connection)
        try publish(connection, revision: 1, sessions: [session(id: 1)])

        manager.createTerminal(on: computerID, cols: 120, rows: 40)
        let placeholderID = try XCTUnwrap(
            manager.terminals.first(where: \.isPlaceholder)?.id
        )
        let req = try XCTUnwrap(manager.pendingCreates.keys.first)

        var rekeys: [(from: TerminalID, to: TerminalID)] = []
        manager.rekeys.sink { rekeys.append($0) }.store(in: &cancellables)

        connection.handle(frame: try Frame.control(.created(id: 7, req: req)))

        let realID = TerminalID(computerID: computerID, sid: 7)
        // Rekeyed in place: same slot (right after the previously active
        // tab 1), no leftover placeholder, focus follows.
        XCTAssertEqual(manager.terminals.map(\.id.sid), [1, 7])
        XCTAssertFalse(manager.terminals.contains { $0.isPlaceholder })
        XCTAssertEqual(manager.activeID, realID)
        XCTAssertEqual(rekeys.count, 1)
        XCTAssertEqual(rekeys.first?.from, placeholderID)
        XCTAssertEqual(rekeys.first?.to, realID)
        XCTAssertTrue(manager.pendingCreates.isEmpty)

        // The next session list refreshes the provisional info.
        try publish(
            connection, revision: 2,
            sessions: [session(id: 1), session(id: 7, title: "vim")]
        )
        XCTAssertEqual(manager.terminals.map(\.info.title), ["zsh", "vim"])
    }

    func testCloseRemovesTabImmediatelyAndSuppressesRelisting() throws {
        let manager = makeManager()
        let connection = try makeConnection()
        manager.attach(connection)
        try publish(connection, revision: 1, sessions: [session(id: 3)])
        XCTAssertEqual(manager.terminals.count, 1)

        let id = TerminalID(computerID: computerID, sid: 3)
        manager.closeTerminal(id)
        XCTAssertEqual(manager.terminals, [])
        XCTAssertNil(manager.activeID)

        // The daemon hasn't applied the close yet and still lists the
        // session: the tab must not reappear.
        try publish(connection, revision: 2, sessions: [session(id: 3)])
        XCTAssertEqual(manager.terminals, [])

        // Confirmed gone; a later same-sid session (counter reuse cannot
        // happen, but a *new* list entry generally) appends normally again.
        try publish(connection, revision: 3, sessions: [])
        try publish(connection, revision: 4, sessions: [session(id: 3)])
        XCTAssertEqual(manager.terminals.map(\.id), [id])
    }

    func testClosingPlaceholderClosesFreshSessionOnEcho() throws {
        let manager = makeManager()
        let connection = try makeConnection()
        manager.attach(connection)
        try publish(connection, revision: 1, sessions: [])

        manager.createTerminal(on: computerID, cols: 120, rows: 40)
        let placeholderID = try XCTUnwrap(manager.terminals.first?.id)
        let req = try XCTUnwrap(manager.pendingCreates.keys.first)

        // The user discards the optimistic tab before the daemon answers.
        manager.closeTerminal(placeholderID)
        XCTAssertEqual(manager.terminals, [])

        // The create still lands on the daemon; its echo must translate into
        // an immediate close, and the session list mentioning it must not
        // resurrect a tab.
        connection.handle(frame: try Frame.control(.created(id: 9, req: req)))
        XCTAssertEqual(manager.terminals, [])
        try publish(connection, revision: 2, sessions: [session(id: 9)])
        XCTAssertEqual(manager.terminals, [])
    }
}
