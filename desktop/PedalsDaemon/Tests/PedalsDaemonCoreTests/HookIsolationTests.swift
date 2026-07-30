import Foundation
import XCTest

@testable import PedalsDaemonCore
import PedalsHookKit

final class HookIsolationTests: XCTestCase {
    func testHookReporterDoesNotWaitForDaemonAcknowledgement() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("pedals-h-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("control.sock").path
        let received = expectation(description: "daemon accepted hook event")
        let server = try ControlServer(path: socketPath) { _ in
            received.fulfill()
            Thread.sleep(forTimeInterval: 0.5)
            return .ok([:])
        }
        defer { server.stop() }

        let started = Date()
        XCTAssertTrue(
            HookSocket.send(
                Data("{\"cmd\":\"agent-event\",\"noReply\":true}\n".utf8),
                socketPath: socketPath,
                budgetMilliseconds: 100
            )
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
        wait(for: [received], timeout: 1)
    }
}
