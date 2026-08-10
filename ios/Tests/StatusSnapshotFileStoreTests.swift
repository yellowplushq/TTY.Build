import Foundation
import XCTest

@testable import TTYBuild

final class StatusSnapshotFileStoreTests: XCTestCase {
    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func append(_ error: Error) {
            lock.withLock { messages.append(String(describing: error)) }
        }

        var all: [String] {
            lock.withLock { messages }
        }
    }

    func testLowerSequenceCannotReplaceStoredSnapshot() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StatusSnapshotFileStore(directory: directory)

        let newest = snapshot(sequence: 42)
        XCTAssertTrue(try store.save(newest).didWrite)

        let result = try store.save(snapshot(sequence: 7))
        XCTAssertFalse(result.didWrite)
        XCTAssertEqual(result.snapshot, newest)
        XCTAssertEqual(try store.load(), newest)
    }

    func testConcurrentIndependentStoreInstancesRemainMonotonic() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failures = FailureBox()
        let highestSequence: UInt64 = 200

        // Each iteration constructs a new store and therefore opens an
        // independent descriptor, just as separate App Group processes do.
        // The final value must be the maximum regardless of completion order.
        DispatchQueue.concurrentPerform(iterations: Int(highestSequence)) { index in
            do {
                let store = StatusSnapshotFileStore(directory: directory)
                _ = try store.save(Self.snapshot(sequence: UInt64(index + 1)))
            } catch {
                failures.append(error)
            }
        }

        XCTAssertEqual(failures.all, [])
        let final = try StatusSnapshotFileStore(directory: directory).load()
        XCTAssertEqual(final?.sequence, highestSequence)
        XCTAssertEqual(final?.totalRunning, Int(highestSequence))
    }

    func testLiveActivityDeleteMutationKeepsActivityIdentityAndQuery() throws {
        let first = PendingPushEndpointMutation.delete(
            .iOSLiveActivityUpdate,
            activityId: "activity one/1"
        )
        let second = PendingPushEndpointMutation.delete(
            .iOSLiveActivityUpdate,
            activityId: "activity-two"
        )
        XCTAssertNotEqual(first.identity, second.identity)

        let encoded = try JSONEncoder().encode(first)
        let decoded = try JSONDecoder().decode(
            PendingPushEndpointMutation.self,
            from: encoded
        )
        XCTAssertEqual(decoded, first)

        let url = StatusAPIClient.pushEndpointURL(
            .iOSLiveActivityUpdate,
            activityId: first.activityId,
            baseURL: URL(string: "https://ttybuild.example/base/")!
        )
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(
            components.path,
            "/base/v2/clients/me/push-endpoints/liveactivity-update"
        )
        XCTAssertEqual(
            components.queryItems,
            [URLQueryItem(name: "activityId", value: "activity one/1")]
        )
    }

    func testSnapshotDecodesRelayAgentEnvelopes() throws {
        let json = """
        {
          "version": 2,
          "totalRunning": 1,
          "agentsRunning": 1,
          "agentsWaiting": 1,
          "agentsDone": 0,
          "computers": [],
          "updatedAt": "2026-07-18T00:00:00Z",
          "sequence": 42,
          "stale": false,
          "recentAgent": {
            "computerID": "computer-a",
            "state": "waiting",
            "updatedAt": "2026-07-18T00:00:01Z",
            "sealed": "c2VhbGVk"
          },
          "moreAgents": [
            {
              "computerID": "computer-b",
              "state": "running",
              "updatedAt": "2026-07-18T00:00:02Z",
              "sealed": "b3RoZXI="
            }
          ]
        }
        """

        let snapshot = try JSONDecoder.ttybuild.decode(
            TTYStatusSnapshot.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(snapshot.recentAgent?.computerID, "computer-a")
        XCTAssertEqual(snapshot.recentAgent?.state, "waiting")
        XCTAssertEqual(snapshot.recentAgent?.sealed, "c2VhbGVk")
        XCTAssertEqual(snapshot.moreAgents?.count, 1)
        XCTAssertEqual(snapshot.moreAgents?.first?.computerID, "computer-b")
    }

    func testSnapshotDecodesRelayResponseWithoutAgentEnvelopes() throws {
        let json = """
        {
          "version": 2,
          "totalRunning": 0,
          "agentsRunning": 0,
          "agentsWaiting": 0,
          "agentsDone": 0,
          "computers": [],
          "updatedAt": "2026-07-18T00:00:00Z",
          "sequence": 7,
          "stale": false
        }
        """

        let snapshot = try JSONDecoder.ttybuild.decode(
            TTYStatusSnapshot.self,
            from: Data(json.utf8)
        )
        XCTAssertNil(snapshot.recentAgent)
        XCTAssertNil(snapshot.moreAgents)
    }

    func testAgentEnvelopesSurviveTheFileStoreRoundTrip() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StatusSnapshotFileStore(directory: directory)

        var snapshot = Self.snapshot(sequence: 5)
        snapshot.recentAgent = .init(
            computerID: "computer-a",
            state: "running",
            updatedAt: Date(timeIntervalSince1970: 1_783_000_000),
            sealed: "c2VhbGVk"
        )
        snapshot.moreAgents = [
            .init(
                computerID: "computer-b",
                state: "waiting",
                updatedAt: Date(timeIntervalSince1970: 1_782_999_000),
                sealed: "b3RoZXI="
            ),
        ]

        XCTAssertTrue(try store.save(snapshot).didWrite)
        XCTAssertEqual(try store.load(), snapshot)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ttybuild-status-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func snapshot(sequence: UInt64) -> TTYStatusSnapshot {
        Self.snapshot(sequence: sequence)
    }

    private static func snapshot(sequence: UInt64) -> TTYStatusSnapshot {
        .init(
            totalRunning: Int(sequence),
            computers: [],
            updatedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            sequence: sequence
        )
    }
}
