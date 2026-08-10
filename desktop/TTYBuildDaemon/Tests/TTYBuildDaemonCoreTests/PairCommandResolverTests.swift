import Foundation
import XCTest

@testable import TTYBuildDaemonCore

final class PairCommandResolverTests: XCTestCase {
    private let validCode = "12345678"

    func testDaemonBusinessErrorIsReportedWithoutOfflineFallback() throws {
        var offlineCalled = false

        XCTAssertThrowsError(
            try PairCommandResolver.resolve(
                reset: true,
                roundTrip: { _ in ["ok": false, "err": "revocation denied"] },
                offline: {
                    offlineCalled = true
                    return self.validCode
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? PairCommandResolver.ResolutionError,
                .daemonRejected("revocation denied")
            )
        }
        XCTAssertFalse(offlineCalled)
    }

    func testOnlyDaemonNotRunningUsesOfflineFallback() throws {
        var offlineCalled = false

        let resolved = try PairCommandResolver.resolve(
            reset: true,
            roundTrip: { _ in
                throw ControlClient.ClientError.daemonNotRunning(socketPath: "/tmp/missing")
            },
            offline: {
                offlineCalled = true
                return self.validCode
            }
        )

        XCTAssertTrue(offlineCalled)
        XCTAssertEqual(resolved, validCode)
    }

    func testSocketIOFailureDoesNotUseOfflineFallback() throws {
        var offlineCalled = false

        XCTAssertThrowsError(
            try PairCommandResolver.resolve(
                reset: true,
                roundTrip: { _ in throw ControlClient.ClientError.ioFailure("timeout") },
                offline: {
                    offlineCalled = true
                    return self.validCode
                }
            )
        ) { error in
            guard case ControlClient.ClientError.ioFailure("timeout") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(offlineCalled)
    }

    func testMalformedSuccessfulReplyDoesNotUseOfflineFallback() throws {
        var offlineCalled = false

        XCTAssertThrowsError(
            try PairCommandResolver.resolve(
                reset: false,
                roundTrip: { _ in ["ok": true, "code": "not-a-code"] },
                offline: {
                    offlineCalled = true
                    return self.validCode
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? PairCommandResolver.ResolutionError,
                .malformedDaemonResponse
            )
        }
        XCTAssertFalse(offlineCalled)
    }
}
