import Combine
@testable import TTYBuild
import TTYBuildKit
import XCTest

/// Reply handling for the remote hook/update ctl messages on the iOS side
/// (PROTOCOL.md §5): replies surface as events with their `req` tag echoed;
/// request forms (which are client→host only) are ignored if mirrored back.
@MainActor
final class ComputerConnectionRemoteManagementTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    private func makeConnection() throws -> ComputerConnection {
        let binding = try ComputerBinding(
            serviceURL: URL(string: "https://example.com")!,
            computerID: "0123456789abcdef0123456789abcdef",
            secret: Data(repeating: 0x42, count: 32)
        )
        return ComputerConnection(
            binding: binding,
            clientID: "fedcba9876543210fedcba9876543210",
            clientToken: "token"
        )
    }

    func testHooksStatusReplyEmitsEvent() throws {
        let connection = try makeConnection()
        var received: [ComputerConnection.Event] = []
        connection.events.sink { received.append($0) }.store(in: &cancellables)

        let list = [
            HookStateInfo(agent: "claude", state: "installed"),
            HookStateInfo(agent: "codex", state: "outdated"),
        ]
        connection.handle(frame: try Frame.control(.hooksStatus(list: list, req: 42)))

        guard case .hooksStatus(let got, let req) = received.first else {
            return XCTFail("expected hooksStatus event, got \(received)")
        }
        XCTAssertEqual(got, list)
        XCTAssertEqual(req, 42)
    }

    func testHooksStatusRequestFormIsIgnored() throws {
        let connection = try makeConnection()
        var received: [ComputerConnection.Event] = []
        connection.events.sink { received.append($0) }.store(in: &cancellables)

        connection.handle(frame: try Frame.control(.hooksStatus(list: nil, req: 1)))
        connection.handle(frame: try Frame.control(.hookInstall(agent: "claude", req: 2)))
        connection.handle(frame: try Frame.control(.hookUninstall(agent: "claude", req: 3)))

        XCTAssertTrue(received.isEmpty)
    }

    func testUpdateStatusReplyEmitsEvent() throws {
        let connection = try makeConnection()
        var received: [ComputerConnection.Event] = []
        connection.events.sink { received.append($0) }.store(in: &cancellables)

        let info = UpdateStatusInfo(
            current: "1.5.0", latest: "1.6.0",
            updateAvailable: true, canInstall: true
        )
        connection.handle(frame: try Frame.control(.updateStatus(info: info, req: 7)))

        guard case .updateStatus(let got, let req) = received.first else {
            return XCTFail("expected updateStatus event, got \(received)")
        }
        XCTAssertEqual(got, info)
        XCTAssertEqual(req, 7)
    }

    func testUpdateRequestFormsAreIgnored() throws {
        let connection = try makeConnection()
        var received: [ComputerConnection.Event] = []
        connection.events.sink { received.append($0) }.store(in: &cancellables)

        connection.handle(frame: try Frame.control(.updateStatus(info: nil, req: 1)))
        connection.handle(frame: try Frame.control(.updateInstall(req: 2)))

        XCTAssertTrue(received.isEmpty)
    }
}
